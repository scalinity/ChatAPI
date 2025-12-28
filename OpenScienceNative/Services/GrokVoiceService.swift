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
/// - PRIVACY: Uses ephemeral URLSession; stores only raw events/transcripts in RAM.
final class GrokVoiceService {
  struct SessionConfig: Hashable {
    var model: String? // optional query param (if required by backend)
    var voice: String // Ara | Rex | Sal | Eve | Leo
    var instructions: String
    var inputFormatType: String = "audio/pcm"
    var inputSampleRate: Int = 24_000
    var outputFormatType: String = "audio/pcm"
    var outputSampleRate: Int = 24_000
  }

  private let urlSession: URLSession
  private var ws: URLSessionWebSocketTask?
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
    onRawEvent: @escaping @Sendable (String) -> Void,
    onTextDelta: @escaping @Sendable (String) -> Void,
    onAudioDeltaPCM24k16: @escaping @Sendable (Data) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) async throws {
    guard let key = apiKey.stringValue(), !key.isEmpty else { throw GrokVoiceError.missingAPIKey }
    guard SecureBytes.validateAPIKeyFormat(key) else { throw GrokVoiceError.invalidAPIKey }

    // NOTE: xAI docs are Cloudflare-protected from this environment; the public guidance indicates
    // compatibility with the OpenAI Realtime event schema. This client implements that schema and
    // records raw events so mismatches are visible and debuggable.
    var components = URLComponents(string: "wss://api.x.ai/v1/realtime")!
    if let model = config.model?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
      components.queryItems = [URLQueryItem(name: "model", value: model)]
    }
    let url = components.url!

    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

    let task = urlSession.webSocketTask(with: request)
    self.ws = task
    task.resume()

    receiveTask?.cancel()
    receiveTask = Task { [weak self] in
      guard let self else { return }
      await self.receiveLoop(onRawEvent: onRawEvent, onTextDelta: onTextDelta, onAudioDeltaPCM24k16: onAudioDeltaPCM24k16, onError: onError)
    }

    try await sendSessionUpdate(config, onRawEvent: onRawEvent)
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    ws?.cancel(with: .goingAway, reason: nil)
    ws = nil
  }

  // MARK: - Outbound events (OpenAI Realtime compatible)

  func sendUserText(_ text: String, onRawEvent: @Sendable (String) -> Void) async throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let event: [String: Any] = [
      "type": "conversation.item.create",
      "item": [
        "type": "message",
        "role": "user",
        "content": [
          ["type": "input_text", "text": trimmed],
        ],
      ],
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
    try await requestResponse(onRawEvent: onRawEvent)
  }

  func appendInputAudioPCMBase64(_ pcmData: Data, onRawEvent: @Sendable (String) -> Void) async throws {
    guard let ws else { throw GrokVoiceError.notConnected }
    _ = ws // silence unused warnings in some toolchains
    let b64 = pcmData.base64EncodedString()
    let event: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": b64,
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  func commitInputAudioAndRequestResponse(onRawEvent: @Sendable (String) -> Void) async throws {
    let commit: [String: Any] = ["type": "input_audio_buffer.commit"]
    try await sendJSON(commit, onRawEvent: onRawEvent)
    try await requestResponse(onRawEvent: onRawEvent)
  }

  private func requestResponse(onRawEvent: @Sendable (String) -> Void) async throws {
    let event: [String: Any] = [
      "type": "response.create",
      "response": [
        "modalities": ["text", "audio"],
      ],
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  private func sendSessionUpdate(_ config: SessionConfig, onRawEvent: @Sendable (String) -> Void) async throws {
    let event: [String: Any] = [
      "type": "session.update",
      "session": [
        "voice": config.voice,
        "instructions": config.instructions,
        "audio": [
          "input": [
            "format": ["type": config.inputFormatType, "rate": config.inputSampleRate],
          ],
          "output": [
            "format": ["type": config.outputFormatType, "rate": config.outputSampleRate],
          ],
        ],
      ],
    ]
    try await sendJSON(event, onRawEvent: onRawEvent)
  }

  private func sendJSON(_ obj: [String: Any], onRawEvent: @Sendable (String) -> Void) async throws {
    guard let ws else { throw GrokVoiceError.notConnected }
    guard JSONSerialization.isValidJSONObject(obj) else { throw GrokVoiceError.invalidMessage }
    let data = try JSONSerialization.data(withJSONObject: obj, options: [])
    let text = String(data: data, encoding: .utf8) ?? ""
    onRawEvent(">> " + text)
    try await ws.send(.string(text))
  }

  // MARK: - Inbound loop

  private func receiveLoop(
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
          onRawEvent("<< " + text)
          handleInbound(text: text, onTextDelta: onTextDelta, onAudioDeltaPCM24k16: onAudioDeltaPCM24k16, onError: onError)
        case .data(let data):
          let text = String(data: data, encoding: .utf8) ?? ""
          onRawEvent("<< " + text)
          handleInbound(text: text, onTextDelta: onTextDelta, onAudioDeltaPCM24k16: onAudioDeltaPCM24k16, onError: onError)
        @unknown default:
          break
        }
      } catch {
        if !Task.isCancelled {
          onError(error.localizedDescription)
        }
        return
      }
    }
  }

  private func handleInbound(
    text: String,
    onTextDelta: @escaping @Sendable (String) -> Void,
    onAudioDeltaPCM24k16: @escaping @Sendable (Data) -> Void,
    onError: @escaping @Sendable (String) -> Void
  ) {
    guard let data = text.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let type = (json["type"] as? String)?.lowercased() else {
      return
    }

    // Text deltas (various compatible event names)
    if type.hasSuffix("text.delta") || type.hasSuffix("transcript.delta") {
      if let delta = json["delta"] as? String {
        onTextDelta(delta)
      }
    }

    // Audio deltas (base64 pcm)
    if type.hasSuffix("audio.delta") {
      if let b64 = json["delta"] as? String,
         let pcm = Data(base64Encoded: b64) {
        onAudioDeltaPCM24k16(pcm)
      }
    }

    // Errors
    if type == "error" || type.hasSuffix(".error") {
      if let err = json["error"] as? [String: Any] {
        onError(err["message"] as? String ?? "Voice error.")
      } else {
        onError("Voice error.")
      }
    }
  }
}


