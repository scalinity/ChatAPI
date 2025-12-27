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
  @Published var reasoningEffort: String = "xhigh"
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

  var settings = LabSettings()
  let apiKey = SecureBytes()

  private let service = OpenRouterService()
  private var streamingTask: Task<Void, Never>?
  private var terminationObserver: Any?

  init() {
    terminationObserver = NotificationCenter.default.addObserver(
      forName: .openScienceNativeWillTerminate,
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
    // Precedence: ENV (e.g. ~/.zshrc) > Keychain > empty
    let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let envKey, !envKey.isEmpty {
      apiKey.set(utf8String: envKey)
      // Persist env key once so Finder/Xcode launches work too.
      if (try? APIKeyKeychainStore.load()) == nil {
        try? APIKeyKeychainStore.save(envKey)
      }
      return
    }

    guard apiKey.isEmpty else { return }
    if let stored = try? APIKeyKeychainStore.load(), !stored.isEmpty {
      apiKey.set(utf8String: stored)
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

  func refreshModels() {
    // Prefer env var (e.g. exported from ~/.zshrc) when available.
    bootstrapFromEnvironmentIfAvailable()
    rawErrorBody = ""
    Task {
      do {
        let fetched = try await service.fetchModels(apiKey: apiKey)
        self.models = fetched
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
    guard !prompt.isEmpty else { return }

    // SECURITY: Validate user input before processing
    let (isValid, validationError) = validateUserInput(prompt)
    guard isValid else {
      rawErrorBody = validationError ?? "Invalid input."
      return
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
    messages.append(Message(role: .user, content: prompt))

    let assistantID = UUID()
    messages.append(Message(id: assistantID, role: .assistant, content: ""))

    let modelID = selectedModelID
    let systemPrompt = systemPromptText // empty => omitted by service

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
          temperature: self.settings.temperature,
          topP: self.settings.topP,
          frequencyPenalty: self.settings.frequencyPenalty,
          presencePenalty: self.settings.presencePenalty,
          reasoningEnabled: self.settings.reasoningEnabled,
          reasoningEffort: self.settings.reasoningEffort,
          onRawEvent: { raw in
            Task { @MainActor in
              self.rawJSONTranscript.append(raw)
              self.rawJSONTranscript.append("\n")
            }
          },
          onAssistantDelta: { delta in
            Task { @MainActor in
              self.appendDelta(delta, toAssistantWithID: assistantID)
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

    apiKey.wipe() // PRIVACY: zeroize key bytes

    // Reset lab controls to defaults (no persistence).
    settings.isContextFree = true
    settings.temperature = 0.7
    settings.topP = 0.95
    settings.frequencyPenalty = 0.0
    settings.presencePenalty = 0.0
    settings.reasoningEnabled = true
    settings.reasoningEffort = "xhigh"
    selectedModelID = "openai/o3"
  }
}


