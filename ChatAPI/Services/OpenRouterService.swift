import Foundation

enum OpenRouterServiceError: Error, LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case invalidResponse
  case httpError(statusCode: Int, body: String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Missing OpenRouter API key."
    case .invalidAPIKey:
      return "Invalid API key format."
    case .invalidResponse:
      return "Invalid response."
    case let .httpError(statusCode, body):
      return "HTTP \(statusCode): \(body)"
    }
  }
}

// MARK: - Security Utilities
// NOTE: API key validation uses SecureBytes.validateAPIKeyFormat(_:) to avoid duplication.

/// SECURITY: Sanitizes error body to prevent sensitive data leakage in UI.
private func sanitizeErrorBody(_ body: String) -> String {
  var sanitized = body

  // Redact potential API keys
  sanitized = sanitized.replacingOccurrences(
    of: #"sk-or-v1-[A-Za-z0-9_-]+"#,
    with: "[REDACTED_API_KEY]",
    options: .regularExpression
  )

  // Redact bearer tokens
  sanitized = sanitized.replacingOccurrences(
    of: #"Bearer\s+[A-Za-z0-9_-]+"#,
    with: "Bearer [REDACTED]",
    options: .regularExpression
  )

  // Redact UUIDs (potential session/request identifiers)
  sanitized = sanitized.replacingOccurrences(
    of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
    with: "[REDACTED_ID]",
    options: [.regularExpression, .caseInsensitive]
  )

  // Limit error body length to prevent UI overflow
  if sanitized.count > 2000 {
    sanitized = String(sanitized.prefix(2000)) + "\n...[truncated]"
  }

  return sanitized
}

/// Direct, ephemeral OpenRouter client.
/// - PRIVACY: Uses ephemeral session configuration (no cookies/cache) and does not log.
final class OpenRouterService {
  private let baseURL = URL(string: "https://openrouter.ai/api/v1")!
  private let session: URLSession
  private let decoder = JSONDecoder()

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.waitsForConnectivity = true
    // Best-effort: disable proxies (system may still enforce).
    config.connectionProxyDictionary = [
      kCFNetworkProxiesHTTPEnable as String: 0,
      kCFNetworkProxiesHTTPSEnable as String: 0,
    ]
    self.session = URLSession(configuration: config)
  }

  func fetchModels(apiKey: SecureBytes) async throws -> [OpenRouterModel] {
    guard let key = apiKey.stringValue(), !key.isEmpty else {
      throw OpenRouterServiceError.missingAPIKey
    }

    // SECURITY: Validate API key format to prevent header injection
    guard SecureBytes.validateAPIKeyFormat(key) else {
      throw OpenRouterServiceError.invalidAPIKey
    }

    var request = URLRequest(url: baseURL.appendingPathComponent("models"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.cachePolicy = .reloadIgnoringLocalCacheData

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OpenRouterServiceError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      // SECURITY: Sanitize error body before exposing
      throw OpenRouterServiceError.httpError(statusCode: http.statusCode, body: sanitizeErrorBody(body))
    }

    // SECURITY: Validate response size to prevent memory exhaustion
    guard data.count <= 10_000_000 else { // 10MB limit
      throw OpenRouterServiceError.invalidResponse
    }

    let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)

    // SECURITY: Limit model count to prevent UI/memory issues
    guard decoded.data.count <= 5000 else {
      throw OpenRouterServiceError.invalidResponse
    }

    return decoded.data
  }

  /// Sends a chat completion request in **streaming** mode and yields incremental deltas.
  ///
  /// - PRIVACY: API key is consumed only to construct an `Authorization` header (RAM-only).
  /// - STATELESSNESS: `isContextFree` controls whether history is included in the `messages` payload.
  /// - MULTIMODAL: Supports image attachments via base64 data URLs.
  func sendMessage(
    apiKey: SecureBytes,
    model: String,
    systemPrompt: String?,
    isContextFree: Bool,
    history: [Message],
    currentUserContent: String,
    currentAttachments: [Attachment] = [],
    temperature: Double,
    topP: Double,
    frequencyPenalty: Double,
    presencePenalty: Double,
    reasoningEnabled: Bool,
    reasoningEffort: String,
    maxTokens: Int? = nil,
    onRawEvent: @Sendable (String) -> Void,
    onAssistantDelta: @Sendable (String) -> Void,
    onReasoningDelta: @Sendable (String) -> Void
  ) async throws {
    guard let key = apiKey.stringValue(), !key.isEmpty else {
      throw OpenRouterServiceError.missingAPIKey
    }

    // SECURITY: Validate API key format to prevent header injection
    guard SecureBytes.validateAPIKeyFormat(key) else {
      throw OpenRouterServiceError.invalidAPIKey
    }

    // Build the request body with multimodal support
    let requestBody = buildMultimodalRequestBody(
      model: model,
      systemPrompt: systemPrompt,
      isContextFree: isContextFree,
      history: history,
      currentUserContent: currentUserContent,
      currentAttachments: currentAttachments,
      temperature: temperature,
      topP: topP,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      reasoningEnabled: reasoningEnabled,
      reasoningEffort: reasoningEffort,
      maxTokens: maxTokens
    )

    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 60
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OpenRouterServiceError.invalidResponse
    }

    guard (200..<300).contains(http.statusCode) else {
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        // SECURITY: Limit error response size to prevent memory exhaustion
        if data.count > 100_000 { break }
      }
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      // SECURITY: Sanitize error body before exposing
      throw OpenRouterServiceError.httpError(statusCode: http.statusCode, body: sanitizeErrorBody(bodyText))
    }

    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }

      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      onRawEvent(String(payload))

      if payload == "[DONE]" {
        break
      }

      guard let jsonData = payload.data(using: .utf8) else { continue }
      guard let chunk = try? decoder.decode(ChatCompletionChunk.self, from: jsonData) else { continue }
      
      // Parse reasoning stream (thinking process) - uses unified accessor for provider compatibility
      if let reasoning = chunk.choices?.first?.delta?.effectiveReasoning, !reasoning.isEmpty {
        onReasoningDelta(reasoning)
      }
      
      // Parse main content stream
      if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
        onAssistantDelta(delta)
      }
    }
  }

  // MARK: - Multimodal Request Builder

  /// Builds a request body dictionary that supports multimodal content.
  /// - Note: Uses dictionary-based encoding to handle mixed content types (text + images).
  private func buildMultimodalRequestBody(
    model: String,
    systemPrompt: String?,
    isContextFree: Bool,
    history: [Message],
    currentUserContent: String,
    currentAttachments: [Attachment],
    temperature: Double,
    topP: Double,
    frequencyPenalty: Double,
    presencePenalty: Double,
    reasoningEnabled: Bool,
    reasoningEffort: String,
    maxTokens: Int?
  ) -> [String: Any] {
    var messages: [[String: Any]] = []

    // Add system message if provided
    let trimmedSystem = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedSystem, !trimmedSystem.isEmpty {
      messages.append([
        "role": "system",
        "content": trimmedSystem,
      ])
    }

    // Add history messages (if not context-free)
    if !isContextFree {
      for msg in history {
        // Use lenient version to avoid throwing in internal code path
        messages.append(msg.toAPIPayloadLenient())
      }
    }

    // Add current user message with attachments
    let currentMessage = Message(
      role: .user,
      content: currentUserContent,
      attachments: currentAttachments
    )
    // Use lenient version - caller should validate attachments before sending
    messages.append(currentMessage.toAPIPayloadLenient())

    // Build request body
    var body: [String: Any] = [
      "model": model,
      "messages": messages,
      "temperature": temperature,
      "top_p": topP,
      "frequency_penalty": frequencyPenalty,
      "presence_penalty": presencePenalty,
      "stream": true,
    ]

    if let maxTokens {
      body["max_tokens"] = maxTokens
    }

    // Add reasoning parameters if enabled
    if reasoningEnabled {
      var reasoning: [String: Any] = ["enabled": true]
      let effort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
      if !effort.isEmpty {
        reasoning["effort"] = effort
      }
      reasoning["exclude"] = false
      body["reasoning"] = reasoning
    }

    return body
  }
}


