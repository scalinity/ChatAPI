import Foundation

enum GrokVoiceError: Error, LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case notConnected
  case invalidMessage

  var errorDescription: String? {
    switch self {
    case .missingAPIKey: return "Missing xAI API key."
    case .invalidAPIKey: return "Invalid xAI API key format."
    case .notConnected: return "Voice session is not connected."
    case .invalidMessage: return "Invalid voice message."
    }
  }
}

/// xAI Grok Voice Agent client (WebSocket Realtime).
/// Uses OpenAI Realtime API compatible format.
/// - PRIVACY: Uses ephemeral URLSession; stores only raw events/transcripts in RAM.
/// - THREAD SAFETY: WebSocket access is protected by NSLock to prevent data races.
final class GrokVoiceService: @unchecked Sendable {
  struct SessionConfig: Hashable {
    var model: String? // optional query param
    var voice: String // Alloy, Echo, Fable, Onyx, Nova, Shimmer (or xAI specific: Ara, Rex, Sal, Eve, Leo)
    var instructions: String
    var turnDetection: TurnDetection = .serverVAD()
    
    struct TurnDetection: Hashable {
      var type: String // "server_vad" or "none"
      var threshold: Double? // 0.0-1.0, sensitivity for VAD
      var prefixPaddingMs: Int? // audio to include before speech
      var silenceDurationMs: Int? // silence duration to end turn
      
      static func serverVAD(threshold: Double = 0.5, prefixPaddingMs: Int = 300, silenceDurationMs: Int = 500) -> TurnDetection {
        TurnDetection(type: "server_vad", threshold: threshold, prefixPaddingMs: prefixPaddingMs, silenceDurationMs: silenceDurationMs)
      }
      
      static var none: TurnDetection {
        TurnDetection(type: "none", threshold: nil, prefixPaddingMs: nil, silenceDurationMs: nil)
      }
    }
  }

  private let urlSession: URLSession
  private let wsLock = NSLock()
  private var _ws: URLSessionWebSocketTask?
  private var ws: URLSessionWebSocketTask? {
    get { wsLock.withLock { _ws } }
    set { wsLock.withLock { _ws = newValue } }
  }
  private var receiveTask: Task<Void, Never>?

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    self.urlSession = URLSession(configuration: config)
  }

  func connect(
    apiKey: SecureBytes,
    config: SessionConfig,
    onSessionReady: @escaping @Sendable () -> Void,
    onRawEvent: @escaping @Sendable (String) -> Void,
    onTextDelta: @escaping @Sendable (String) -> Void,
    onAudioDeltaPCM24k16: @escaping @Sendable (Data) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    guard let key = apiKey.stringValue(), !key.isEmpty else { throw GrokVoiceError.missingAPIKey }
    // Note: xAI keys may have various formats, so we only do minimal validation
    guard !key.contains("\r"), !key.contains("\n") else { throw GrokVoiceError.invalidAPIKey }

    // xAI Realtime WebSocket endpoint
    var components = URLComponents(string: "wss://api.x.ai/v1/realtime")!
    if let model = config.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
      components.queryItems = [URLQueryItem(name: "model", value: model)]
    }
    let url = components.url!

    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    // OpenAI Realtime uses this beta header
    request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

    let task = urlSession.webSocketTask(with: request)
    self.ws = task
    task.resume()

    receiveTask?.cancel()
    receiveTask = Task { [weak self] in
      guard let self else { return }
      await self.receiveLoop(
        onSessionReady: onSessionReady,
        onRawEvent: onRawEvent,
        onTextDelta: onTextDelta,
        onAudioDeltaPCM24k16: onAudioDeltaPCM24k16,
        onError: onError
      )
    }

    try await sendSessionUpdate(config, onRawEvent: onRawEvent)
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    ws?.cancel(with: .goingAway, reason: nil)
    ws = nil
  }

  // MARK: - Outbound events (OpenAI Realtime API)

  func sendUserText(_ text: String, onRawEvent: @Sendable (String) -> Void) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    
    // Create conversation item
    let event: [String: Any] = [
      "type": "conversation.item.create",
      "item": [
        "type": "message",
        "role": "user",
        "content": [
          ["type": "input_text", "text": trimmed]
        ]
      ]
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
    
    // Request response with both text and audio
    try await requestResponse(onRawEvent: onRawEvent)
  }

  func appendInputAudioPCMBase64(_ pcmData: Data, onRawEvent: @Sendable (String) -> Void) async throws {
    guard ws != nil else { throw GrokVoiceError.notConnected }
    let b64 = pcmData.base64EncodedString()
    let event: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": b64
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  func commitInputAudioAndRequestResponse(onRawEvent: @Sendable (String) -> Void) async throws {
    // Commit the audio buffer
    let commit: [String: Any] = ["type": "input_audio_buffer.commit"]
    try await sendJSON(commit, onRawEvent: onRawEvent)
    
    // Request response
    try await requestResponse(onRawEvent: onRawEvent)
  }
  
  /// Clear the input audio buffer (useful when interrupting)
  func clearInputAudioBuffer(onRawEvent: @Sendable (String) -> Void) async throws {
    let event: [String: Any] = ["type": "input_audio_buffer.clear"]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  private func requestResponse(onRawEvent: @Sendable (String) -> Void) async throws {
    let event: [String: Any] = [
      "type": "response.create",
      "response": [
        "modalities": ["text", "audio"]
      ]
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  private func sendSessionUpdate(_ config: SessionConfig, onRawEvent: @Sendable (String) -> Void) async throws {
    // Build turn_detection object
    var turnDetection: [String: Any] = ["type": config.turnDetection.type]
    if let threshold = config.turnDetection.threshold {
      turnDetection["threshold"] = threshold
    }
    if let prefix = config.turnDetection.prefixPaddingMs {
      turnDetection["prefix_padding_ms"] = prefix
    }
    if let silence = config.turnDetection.silenceDurationMs {
      turnDetection["silence_duration_ms"] = silence
    }
    if config.turnDetection.type == "server_vad" {
      // Ensure the server auto-creates responses when it detects end-of-turn.
      turnDetection["create_response"] = true
    }
    
    // OpenAI Realtime session.update format
    let event: [String: Any] = [
      "type": "session.update",
      "session": [
        "modalities": ["text", "audio"],
        "instructions": config.instructions,
        "voice": config.voice.lowercased(),
        "input_audio_format": "pcm16",
        "output_audio_format": "pcm16",
        "input_audio_transcription": [
          "model": "whisper-1"
        ],
        "turn_detection": turnDetection
      ]
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  private func clipForLog(_ text: String, maxChars: Int = 1200) -> String {
    guard text.count > maxChars else { return text }
    let prefix = String(text.prefix(maxChars))
    return "\(prefix)… <truncated: \(text.count) chars>"
  }

  private func sendJSON(_ obj: [String: Any], onRawEvent: @Sendable (String) -> Void) async throws {
    guard let ws else { throw GrokVoiceError.notConnected }
    guard JSONSerialization.isValidJSONObject(obj) else { throw GrokVoiceError.invalidMessage }
    let data = try JSONSerialization.data(withJSONObject: obj, options: [])
    let text = String(data: data, encoding: .utf8) ?? ""

    if let type = obj["type"] as? String, type == "input_audio_buffer.append", let audio = obj["audio"] as? String {
      onRawEvent(">> {\"type\":\"input_audio_buffer.append\",\"audio\":\"<\(audio.count) chars>\"}")
    } else {
      onRawEvent(">> \(clipForLog(text))")
    }
    try await ws.send(.string(text))
  }

  // MARK: - Inbound loop

  private func receiveLoop(
    onSessionReady: @escaping @Sendable () -> Void,
    onRawEvent: @escaping @Sendable (String) -> Void,
    onTextDelta: @escaping @Sendable (String) -> Void,
    onAudioDeltaPCM24k16: @escaping @Sendable (Data) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async {
    while !Task.isCancelled {
      guard let ws else { return }
      do {
        let msg = try await ws.receive()
        switch msg {
        case .string(let text):
          onRawEvent("<< \(clipForLog(text))")
          handleInbound(
            text: text,
            onSessionReady: onSessionReady,
            onTextDelta: onTextDelta,
            onAudioDeltaPCM24k16: onAudioDeltaPCM24k16,
            onError: onError
          )
        case .data(let data):
          let text = String(data: data, encoding: .utf8) ?? "[binary data]"
          onRawEvent("<< \(clipForLog(text))")
          handleInbound(
            text: text,
            onSessionReady: onSessionReady,
            onTextDelta: onTextDelta,
            onAudioDeltaPCM24k16: onAudioDeltaPCM24k16,
            onError: onError
          )
        @unknown default:
          break
        }
      } catch {
        if !Task.isCancelled {
          onError("WebSocket error: \(error.localizedDescription)")
        }
        return
      }
    }
  }

  private func handleInbound(
    text: String,
    onSessionReady: @escaping @Sendable () -> Void,
    onTextDelta: @escaping @Sendable (String) -> Void,
    onAudioDeltaPCM24k16: @escaping @Sendable (Data) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) {
    guard let data = text.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let type = json["type"] as? String else {
      return
    }

    // Session created/updated confirmations
    if type == "session.created" || type == "session.updated" {
      // Session is ready
      onSessionReady()
      return
    }
    
    // User's speech transcribed (input_audio_transcription.completed)
    if type == "conversation.item.input_audio_transcription.completed" {
      if let transcript = json["transcript"] as? String, !transcript.isEmpty {
        onTextDelta("\n👤 You: \(transcript)\n")
      }
      return
    }
    
    // Response started - add newline for assistant
    if type == "response.created" {
      onTextDelta("\n🤖 Grok: ")
      return
    }
    
    // Response audio transcript delta (what assistant is saying, transcribed)
    if type == "response.audio_transcript.delta" {
      if let delta = json["delta"] as? String {
        onTextDelta(delta)
      }
      return
    }
    
    // Response text delta (text-only response)
    if type == "response.text.delta" {
      if let delta = json["delta"] as? String {
        onTextDelta(delta)
      }
      return
    }
    
    // Response audio delta (actual audio data)
    if type == "response.audio.delta" {
      // Try "delta" field first (OpenAI format)
      if let b64 = json["delta"] as? String, let pcm = Data(base64Encoded: b64) {
        onAudioDeltaPCM24k16(pcm)
        return
      }
      // Try "audio" field (alternative format)
      if let b64 = json["audio"] as? String, let pcm = Data(base64Encoded: b64) {
        onAudioDeltaPCM24k16(pcm)
        return
      }
    }
    
    // Response completed
    if type == "response.done" {
      onTextDelta("\n")
      return
    }
    
    // Speech started (user started talking - can be used for interruption)
    if type == "input_audio_buffer.speech_started" {
      // User started speaking - could interrupt here
      return
    }
    
    // Speech stopped (user stopped talking)
    if type == "input_audio_buffer.speech_stopped" {
      // User stopped speaking - audio will be committed automatically with server_vad
      return
    }
    
    // Input audio buffer committed (happens automatically with server_vad)
    if type == "input_audio_buffer.committed" {
      return
    }

    // Error handling
    if type == "error" {
      if let errorObj = json["error"] as? [String: Any] {
        let message = errorObj["message"] as? String ?? "Unknown error"
        let code = errorObj["code"] as? String ?? ""
        onError("\(code): \(message)")
      } else {
        onError("Voice error occurred.")
      }
      return
    }
  }
}

