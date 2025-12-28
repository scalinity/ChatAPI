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

  // MARK: - Streaming (SSE) Delegate

  /// Delegate-based SSE parser that avoids chunkiness from partial JSON frames and buffering.
  private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
    private let decoder: JSONDecoder
    private let onRawEvent: @Sendable (String) -> Void
    private let onAssistantDelta: @Sendable (String) -> Void
    private let onReasoningDelta: @Sendable (String) -> Void
    private let onComplete: @Sendable (Result<Void, Error>) -> Void

    private var buffer = Data()
    private var errorBody = Data()
    private var statusCode: Int?

    private let completionLock = NSLock()
    private var didComplete = false

    private weak var session: URLSession?
    private weak var task: URLSessionTask?

    init(
      decoder: JSONDecoder,
      onRawEvent: @escaping @Sendable (String) -> Void,
      onAssistantDelta: @escaping @Sendable (String) -> Void,
      onReasoningDelta: @escaping @Sendable (String) -> Void,
      onComplete: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
      self.decoder = decoder
      self.onRawEvent = onRawEvent
      self.onAssistantDelta = onAssistantDelta
      self.onReasoningDelta = onReasoningDelta
      self.onComplete = onComplete
    }

    func bind(session: URLSession, task: URLSessionTask) {
      self.session = session
      self.task = task
    }

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      if let http = response as? HTTPURLResponse {
        statusCode = http.statusCode
      }
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      // If HTTP status is an error, buffer response body (up to 100KB) and let completion handle it.
      if let code = statusCode, !(200..<300).contains(code) {
        if errorBody.count < 100_000 {
          let remaining = 100_000 - errorBody.count
          errorBody.append(data.prefix(remaining))
        }
        return
      }

      buffer.append(data)
      processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      // HTTP error (non-2xx)
      if let code = statusCode, !(200..<300).contains(code) {
        let bodyText = String(data: errorBody, encoding: .utf8) ?? ""
        complete(.failure(OpenRouterServiceError.httpError(statusCode: code, body: sanitizeErrorBody(bodyText))))
        return
      }

      if let nsError = error as NSError? {
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
          complete(.failure(CancellationError()))
        } else {
          complete(.failure(nsError))
        }
        return
      }

      complete(.success(()))
    }

    private func complete(_ result: Result<Void, Error>) {
      completionLock.lock()
      if didComplete {
        completionLock.unlock()
        return
      }
      didComplete = true
      completionLock.unlock()

      onComplete(result)
      session?.finishTasksAndInvalidate()
    }

    private func processBuffer() {
      while let eventData = nextEventFromBuffer() {
        parseEvent(eventData)
      }
    }

    private func nextEventFromBuffer() -> Data? {
      let lf = Data("\n\n".utf8)
      let crlf = Data("\r\n\r\n".utf8)

      let lfRange = buffer.range(of: lf)
      let crlfRange = buffer.range(of: crlf)

      // Pick the earliest delimiter, supporting both LF and CRLF.
      let chosenRange: Range<Data.Index>?
      switch (lfRange, crlfRange) {
      case (nil, nil):
        chosenRange = nil
      case (let a?, nil):
        chosenRange = a
      case (nil, let b?):
        chosenRange = b
      case (let a?, let b?):
        chosenRange = a.lowerBound < b.lowerBound ? a : b
      }

      guard let range = chosenRange else { return nil }
      let end = range.upperBound
      let event = buffer.subdata(in: 0..<end)
      buffer.removeSubrange(0..<end)
      return event
    }

    private func parseEvent(_ eventData: Data) {
      guard let eventString = String(data: eventData, encoding: .utf8) else { return }

      // Collect all `data:` lines in the SSE event. (OpenRouter typically sends exactly one.)
      var dataLines: [String] = []
      for rawLine in eventString.split(whereSeparator: \.isNewline) {
        let line = String(rawLine)
        if line.hasPrefix("data:") {
          let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
          dataLines.append(payload)
        }
      }

      guard !dataLines.isEmpty else { return }
      let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      handlePayload(payload)
    }

    private func handlePayload(_ payload: String) {
      onRawEvent(payload)

      if payload == "[DONE]" {
        complete(.success(()))
        task?.cancel()
        return
      }

      guard let jsonData = payload.data(using: .utf8) else { return }
      guard let chunk = try? decoder.decode(ChatCompletionChunk.self, from: jsonData) else { return }

      if let reasoning = chunk.choices?.first?.delta?.effectiveReasoning, !reasoning.isEmpty {
        onReasoningDelta(reasoning)
      }
      if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
        onAssistantDelta(delta)
      }
    }
  }

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
    onRawEvent: @escaping @Sendable (String) -> Void,
    onAssistantDelta: @escaping @Sendable (String) -> Void,
    onReasoningDelta: @escaping @Sendable (String) -> Void
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
    // Best-effort: ask intermediaries not to buffer SSE.
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    request.setValue("no", forHTTPHeaderField: "X-Accel-Buffering")
    request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])

    // Delegate-based streaming to avoid chunkiness from partial SSE frames.
    final class TaskBox: @unchecked Sendable {
      private let lock = NSLock()
      private var _task: URLSessionTask?
      func set(_ task: URLSessionTask) { lock.withLock { _task = task } }
      func cancel() { lock.withLock { _task?.cancel() } }
    }

    let taskBox = TaskBox()

    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let delegate = SSEStreamDelegate(
          decoder: self.decoder,
          onRawEvent: onRawEvent,
          onAssistantDelta: onAssistantDelta,
          onReasoningDelta: onReasoningDelta
        ) { result in
          switch result {
          case .success:
            cont.resume()
          case .failure(let error):
            cont.resume(throwing: error)
          }
        }

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        config.httpShouldUsePipelining = true
        config.connectionProxyDictionary = [
          kCFNetworkProxiesHTTPEnable as String: 0,
          kCFNetworkProxiesHTTPSEnable as String: 0,
        ]

        // Use a dedicated session for delegate streaming.
        let streamSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = streamSession.dataTask(with: request)
        delegate.bind(session: streamSession, task: task)
        taskBox.set(task)
        task.resume()
      }
    }, onCancel: {
      taskBox.cancel()
    })
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


