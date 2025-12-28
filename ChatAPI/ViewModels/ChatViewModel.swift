import Combine
import Foundation
import SwiftUI

// MARK: - Security Constants

/// SECURITY: Input validation limits to prevent DoS and memory exhaustion.
private enum SecurityLimits {
  /// Maximum prompt length in characters (100KB)
  static let maxPromptLength = 100_000

  /// Maximum system prompt length in characters (50KB)
  static let maxSystemPromptLength = 50_000

  /// Maximum number of messages in history
  static let maxHistoryMessages = 1000

  /// Maximum raw JSON transcript length to prevent memory exhaustion (500KB)
  static let maxTranscriptLength = 500_000
}

/// SECURITY: Validates user input for safety.
private func validateUserInput(_ input: String) -> (isValid: Bool, error: String?) {
  // Check for null bytes (potential injection)
  if input.contains("\0") {
    return (false, "Input contains invalid characters.")
  }

  // Check length
  if input.count > SecurityLimits.maxPromptLength {
    return (false, "Input exceeds maximum length (\(SecurityLimits.maxPromptLength) characters).")
  }

  // Check for valid UTF-8 (should always pass for Swift String, but defense in depth)
  if input.utf8.withContiguousStorageIfAvailable({ _ in true }) == nil {
    // Non-contiguous storage is fine, just checking it's valid
  }

  return (true, nil)
}

@MainActor
final class LabSettings: ObservableObject {
  // SCIENTIFIC PROTOCOL: Stateless-by-default
  @Published var isContextFree: Bool = true

  // Parameters
  @Published var temperature: Double = 0.7
  @Published var topP: Double = 0.95
  @Published var frequencyPenalty: Double = 0.0
  @Published var presencePenalty: Double = 0.0

  // “Max reasoning” defaults (explicit, user-visible control)
  @Published var reasoningEnabled: Bool = true
  @Published var reasoningEffort: String = "high"
}

@MainActor
final class ChatViewModel: ObservableObject {
  @Published var messages: [Message] = []
  @Published var inputText: String = ""
  @Published var systemPromptText: String = "" // empty => nil (omitted from payload)

  @Published var rawJSONTranscript: String = ""
  @Published var rawErrorBody: String = ""

  @Published var models: [OpenRouterModel] = []
  @Published var selectedModelID: String = "openai/o3" // sensible default; user may choose any fetched model

  @Published var isSending: Bool = false
  @Published var isInspectorPresented: Bool = true

  /// Current attachments pending send (images/files).
  @Published var pendingAttachments: [Attachment] = []

  /// MCP connectors (Model Context Protocol) for agent/tool workflows (RAM-only).
  @Published var mcpConnectors: [MCPConnector] = []

  var settings = LabSettings()
  let apiKey = SecureBytes()

  /// Cached grouped models (invalidated when models changes).
  private var _groupedModelsCache: [ModelCatalog.ProviderGroup]?

  /// Models sorted with newest first (reversed order).
  var sortedModels: [OpenRouterModel] {
    models.reversed()
  }

  /// Models grouped by provider family, sorted by OpenRouter popularity.
  /// Cached to avoid recalculation on every SwiftUI re-render.
  var groupedModels: [ModelCatalog.ProviderGroup] {
    if let cached = _groupedModelsCache { return cached }
    let result = ModelCatalog.groupByProvider(models)
    _groupedModelsCache = result
    return result
  }

  var selectedModel: OpenRouterModel? {
    models.first(where: { $0.id == selectedModelID })
  }

  /// Models that officially advertise image output capability via OpenRouter metadata.
  var imageOutputModels: [OpenRouterModel] {
    models.filter { $0.capabilities.supportsImageOutput }
  }

  /// Models that officially advertise video output capability via OpenRouter metadata.
  var videoOutputModels: [OpenRouterModel] {
    models.filter { $0.capabilities.supportsVideoOutput }
  }

  /// Most recent image-capable model by OpenRouter `created` metadata (fallback: highest context length).
  var recommendedImageModelID: String? {
    imageOutputModels
      .sorted(by: OpenRouterModelComparator.compareNewestFirst)
      .first?
      .id
  }

  /// Most recent video-capable model by OpenRouter `created` metadata (fallback: highest context length).
  var recommendedVideoModelID: String? {
    videoOutputModels
      .sorted(by: OpenRouterModelComparator.compareNewestFirst)
      .first?
      .id
  }

  private let service = OpenRouterService()
  private var streamingTask: Task<Void, Never>?
  private var terminationObserver: Any?
  private let mcpClient = MCPHTTPClient()

  init() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: .chatAPIWillTerminate,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        self?.wipe()
      }
    }
  }

  deinit {
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
    }
  }

  func bootstrapFromEnvironmentIfAvailable() {
    // Only check environment variable - no keychain access to avoid repeated auth dialogs
    let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let envKey, !envKey.isEmpty {
      apiKey.set(utf8String: envKey)
      return
    }
    // Don't auto-load from keychain - user must click "Load" to avoid password prompts
  }

  /// Explicitly load API key from keychain (user-initiated to avoid surprise auth dialogs).
  func loadAPIKeyFromKeychain() {
    guard apiKey.isEmpty else { return }
    do {
      if let stored = try APIKeyKeychainStore.load(), !stored.isEmpty {
        apiKey.set(utf8String: stored)
      }
    } catch {
      rawErrorBody = "Keychain access failed: \(error.localizedDescription)"
    }
  }

  func setAPIKeyPersistently(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    apiKey.set(utf8String: trimmed)
    try? APIKeyKeychainStore.save(trimmed)
  }

  func forgetAPIKey() {
    // PRIVACY: Wipe RAM; also delete persistent key (user-requested).
    apiKey.wipe()
    try? APIKeyKeychainStore.delete()
  }

  func stop() {
    streamingTask?.cancel()
    streamingTask = nil
    isSending = false
  }

  /// Clears the current chat session while preserving persistent configuration
  /// such as the API key (Keychain) and MCP connector list.
  func resetSession() {
    stop()
    messages.removeAll(keepingCapacity: false)
    inputText.removeAll(keepingCapacity: false)
    systemPromptText.removeAll(keepingCapacity: false)
    rawJSONTranscript.removeAll(keepingCapacity: false)
    rawErrorBody.removeAll(keepingCapacity: false)
    pendingAttachments.removeAll(keepingCapacity: false)
  }

  // MARK: - Attachment Management

  /// Adds an attachment from a file URL.
  func addAttachment(from url: URL) {
    guard let attachment = Attachment.fromURL(url) else {
      rawErrorBody = "Failed to read file: \(url.lastPathComponent)"
      return
    }
    addAttachment(attachment)
  }

  /// Adds an already-materialized attachment (RAM-only), enforcing security limits.
  func addAttachment(_ attachment: Attachment) {
    rawErrorBody = ""

    // SECURITY: Limit attachment size (20MB per file)
    guard attachment.size <= 20_000_000 else {
      rawErrorBody = "File too large: \(attachment.filename) (\(attachment.formattedSize)). Maximum is 20MB."
      return
    }

    // SECURITY: Limit total attachments
    guard pendingAttachments.count < 10 else {
      rawErrorBody = "Maximum 10 attachments allowed."
      return
    }

    pendingAttachments.append(attachment)
  }

  /// Removes an attachment by ID.
  func removeAttachment(_ id: UUID) {
    pendingAttachments.removeAll { $0.id == id }
  }

  /// Clears all pending attachments.
  func clearAttachments() {
    pendingAttachments.removeAll()
  }

  // MARK: - MCP Connectors (HTTP JSON-RPC)

  func addMCPConnector(name: String, endpoint: String) {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, let url = URL(string: trimmedEndpoint) else {
      rawErrorBody = "Invalid connector name or URL."
      return
    }
    guard url.scheme == "http" || url.scheme == "https" else {
      rawErrorBody = "Connector URL must be http(s)."
      return
    }
    mcpConnectors.append(MCPConnector(name: trimmedName, endpoint: trimmedEndpoint))
  }

  func removeMCPConnector(_ id: UUID) {
    mcpConnectors.removeAll { $0.id == id }
  }

  func refreshMCPTools(for id: UUID) {
    guard let idx = mcpConnectors.firstIndex(where: { $0.id == id }) else { return }
    mcpConnectors[idx].status = .connecting
    mcpConnectors[idx].lastError = nil
    mcpConnectors[idx].lastRawResponse = nil

    Task {
      do {
        let endpoint = mcpConnectors[idx].endpoint
        let (tools, raw) = try await mcpClient.listTools(endpoint: endpoint)
        await MainActor.run {
          guard let idx2 = self.mcpConnectors.firstIndex(where: { $0.id == id }) else { return }
          self.mcpConnectors[idx2].tools = tools
          self.mcpConnectors[idx2].lastRawResponse = raw
          self.mcpConnectors[idx2].status = .connected
        }
      } catch {
        await MainActor.run {
          guard let idx2 = self.mcpConnectors.firstIndex(where: { $0.id == id }) else { return }
          self.mcpConnectors[idx2].status = .error
          self.mcpConnectors[idx2].lastError = error.localizedDescription
        }
      }
    }
  }

  func refreshModels() {
    // Prefer env var (e.g. exported from ~/.zshrc) when available.
    bootstrapFromEnvironmentIfAvailable()
    rawErrorBody = ""
    Task {
      do {
        let fetched = try await service.fetchModels(apiKey: apiKey)
        self.models = fetched
        self._groupedModelsCache = nil // Invalidate cache
        if !fetched.contains(where: { $0.id == self.selectedModelID }) {
          self.selectedModelID = Self.pickDefaultModelID(from: fetched) ?? self.selectedModelID
        }
      } catch {
        self.rawErrorBody = error.localizedDescription
      }
    }
  }

  func send() {
    // Prefer env var (e.g. exported from ~/.zshrc) when available.
    bootstrapFromEnvironmentIfAvailable()
    let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = pendingAttachments
    guard !prompt.isEmpty || !attachments.isEmpty else { return }

    if !prompt.isEmpty {
      // SECURITY: Validate user input before processing
      let (isValid, validationError) = validateUserInput(prompt)
      guard isValid else {
        rawErrorBody = validationError ?? "Invalid input."
        return
      }
    }

    // SECURITY: Validate system prompt if present
    let trimmedSystemPrompt = systemPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSystemPrompt.isEmpty {
      if trimmedSystemPrompt.count > SecurityLimits.maxSystemPromptLength {
        rawErrorBody = "System prompt exceeds maximum length."
        return
      }
      if trimmedSystemPrompt.contains("\0") {
        rawErrorBody = "System prompt contains invalid characters."
        return
      }
    }

    stop()
    rawJSONTranscript = ""
    rawErrorBody = ""
    isSending = true

    // SECURITY: Limit history size to prevent memory issues
    var history = messages
    if history.count > SecurityLimits.maxHistoryMessages {
      history = Array(history.suffix(SecurityLimits.maxHistoryMessages))
    }

    inputText = ""
    pendingAttachments.removeAll()
    messages.append(Message(role: .user, content: prompt, attachments: attachments))

    let assistantID = UUID()
    messages.append(Message(id: assistantID, role: .assistant, content: ""))

    let modelID = selectedModelID
    let systemPrompt = systemPromptText // empty => omitted by service
    let modelMeta = selectedModel
    let reasoningAllowed = modelMeta?.capabilities.supportsReasoning ?? true

    streamingTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.service.sendMessage(
          apiKey: self.apiKey,
          model: modelID,
          systemPrompt: systemPrompt,
          isContextFree: self.settings.isContextFree,
          history: history,
          currentUserContent: prompt,
          currentAttachments: attachments,
          temperature: self.settings.temperature,
          topP: self.settings.topP,
          frequencyPenalty: self.settings.frequencyPenalty,
          presencePenalty: self.settings.presencePenalty,
          // Use official metadata: only send `reasoning` if the model supports it.
          reasoningEnabled: self.settings.reasoningEnabled && reasoningAllowed,
          reasoningEffort: self.settings.reasoningEffort,
          onRawEvent: { [weak self] raw in
            // Use immediate MainActor dispatch to avoid batching
            DispatchQueue.main.async {
              guard let self else { return }
              self.rawJSONTranscript.append(raw)
              self.rawJSONTranscript.append("\n")
              // SECURITY: Truncate to prevent memory exhaustion
              if self.rawJSONTranscript.count > SecurityLimits.maxTranscriptLength {
                self.rawJSONTranscript = String(self.rawJSONTranscript.suffix(SecurityLimits.maxTranscriptLength))
              }
            }
          },
          onAssistantDelta: { [weak self] delta in
            // Immediate dispatch for smooth character-by-character streaming
            DispatchQueue.main.async {
              guard let self else { return }
              self.appendDelta(delta, toAssistantWithID: assistantID)
            }
          },
          onReasoningDelta: { [weak self] reasoning in
            // Immediate dispatch for smooth reasoning stream
            DispatchQueue.main.async {
              guard let self else { return }
              self.appendReasoningDelta(reasoning, toAssistantWithID: assistantID)
            }
          }
        )
        await MainActor.run { self.isSending = false }
      } catch is CancellationError {
        await MainActor.run { self.isSending = false }
      } catch let OpenRouterServiceError.httpError(_, body) {
        await MainActor.run {
          self.rawErrorBody = body
          self.isSending = false
        }
      } catch {
        await MainActor.run {
          self.rawErrorBody = error.localizedDescription
          self.isSending = false
        }
      }
    }
  }

  private func appendDelta(_ delta: String, toAssistantWithID id: UUID) {
    guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[idx].content.append(delta)
  }
  
  private func appendReasoningDelta(_ reasoning: String, toAssistantWithID id: UUID) {
    guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[idx].reasoning_content.append(reasoning)
  }

  private static func pickDefaultModelID(from models: [OpenRouterModel]) -> String? {
    // Heuristic: prefer well-known top-tier IDs when present; otherwise fall back to first.
    let preferred = [
      "openai/o3",
      "openai/o1",
      "openai/gpt-4.1",
      "openai/gpt-4o",
      "anthropic/claude-3.5-sonnet",
      "anthropic/claude-3.7-sonnet",
    ]
    for id in preferred {
      if models.contains(where: { $0.id == id }) {
        return id
      }
    }
    return models.first?.id
  }

  func wipe() {
    // PRIVACY: Best-effort RAM wipe. (Process exit still provides final teardown.)
    stop()

    messages.removeAll(keepingCapacity: false)
    inputText.removeAll(keepingCapacity: false)
    systemPromptText.removeAll(keepingCapacity: false)
    rawJSONTranscript.removeAll(keepingCapacity: false)
    rawErrorBody.removeAll(keepingCapacity: false)
    models.removeAll(keepingCapacity: false)
    _groupedModelsCache = nil // Invalidate cache
    pendingAttachments.removeAll(keepingCapacity: false)
    mcpConnectors.removeAll(keepingCapacity: false)

    apiKey.wipe() // PRIVACY: zeroize key bytes

    // Reset lab controls to defaults (no persistence).
    settings.isContextFree = true
    settings.temperature = 0.7
    settings.topP = 0.95
    settings.frequencyPenalty = 0.0
    settings.presencePenalty = 0.0
    settings.reasoningEnabled = true
    settings.reasoningEffort = "high"
    selectedModelID = "openai/o3"
  }
}

// MARK: - MCP Models (RAM-only)

struct MCPTool: Identifiable, Hashable {
  let id: String
  var name: String { id }
  var description: String?
  var inputSchemaJSON: String?
}

struct MCPConnector: Identifiable, Hashable {
  enum Status: String, Hashable {
    case disconnected
    case connecting
    case connected
    case error
  }

  let id: UUID
  var name: String
  var endpoint: String
  var status: Status
  var tools: [MCPTool]
  var lastError: String?
  var lastRawResponse: String?

  init(
    id: UUID = UUID(),
    name: String,
    endpoint: String,
    status: Status = .disconnected,
    tools: [MCPTool] = [],
    lastError: String? = nil,
    lastRawResponse: String? = nil
  ) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.status = status
    self.tools = tools
    self.lastError = lastError
    self.lastRawResponse = lastRawResponse
  }
}

// MARK: - MCP JSON-RPC over HTTP (minimal, no deps)

private struct MCPHTTPClient {
  private let session: URLSession

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    self.session = URLSession(configuration: config)
  }

  func listTools(endpoint: String) async throws -> ([MCPTool], String) {
    guard let url = URL(string: endpoint) else {
      throw URLError(.badURL)
    }

    let body: [String: Any] = [
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/list",
      "params": [:],
    ]
    let data = try JSONSerialization.data(withJSONObject: body, options: [])

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 20
    request.httpBody = data

    let (respData, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200..<300).contains(http.statusCode) else {
      let raw = String(data: respData, encoding: .utf8) ?? ""
      throw OpenRouterServiceError.httpError(statusCode: http.statusCode, body: raw)
    }

    let raw = String(data: respData, encoding: .utf8) ?? ""

    // Best-effort parse: result.tools -> [{name, description, inputSchema}]
    guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
      return ([], raw)
    }
    guard let result = json["result"] as? [String: Any] else {
      return ([], raw)
    }
    guard let toolsArr = result["tools"] as? [[String: Any]] else {
      return ([], raw)
    }

    let tools: [MCPTool] = toolsArr.compactMap { dict in
      guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
      let desc = dict["description"] as? String
      let schemaObj = dict["inputSchema"] ?? dict["input_schema"]
      let schemaJSON: String? = {
        guard let schemaObj else { return nil }
        guard JSONSerialization.isValidJSONObject(schemaObj),
              let d = try? JSONSerialization.data(withJSONObject: schemaObj, options: [.prettyPrinted]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
      }()
      return MCPTool(id: name, description: desc, inputSchemaJSON: schemaJSON)
    }

    return (tools, raw)
  }
}



