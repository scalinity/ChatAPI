import AVFoundation
import Combine
import Foundation
import os

// MARK: - Thread-safe Audio Handler (for realtime audio callbacks)

/// Handles audio I/O in a thread-safe manner, separate from @MainActor isolation.
/// This allows audio callbacks to run on realtime threads without latency.
private final class AudioHandler: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var inputConverter: AVAudioConverter?
  private var inputFormat: AVAudioFormat?  // PCM16 24kHz mono for input
  private var outputFormat: AVAudioFormat? // Float32 24kHz mono for playback

  private let lock = NSLock()
  private var _isRecording = false
  private var _isPlayingAudio = false
  private var _pendingBuffers = 0
  private var _continuation: AsyncStream<Data>.Continuation?

  var isRecording: Bool {
    get { lock.withLock { _isRecording } }
    set { lock.withLock { _isRecording = newValue } }
  }

  /// When true, mic capture is paused to prevent echo
  var isPlayingAudio: Bool {
    get { lock.withLock { _isPlayingAudio } }
    set { lock.withLock { _isPlayingAudio = newValue } }
  }

  var continuation: AsyncStream<Data>.Continuation? {
    get { lock.withLock { _continuation } }
    set { lock.withLock { _continuation = newValue } }
  }

  func configure() throws {
    if !engine.attachedNodes.contains(player) {
      engine.attach(player)
    }

    // PCM16 format for xAI API (input/output wire format)
    guard let pcm16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true) else {
      throw NSError(domain: "ChatAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM16 audio format."])
    }

    // Float32 format for AVAudioEngine playback (required by mixer)
    guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false) else {
      throw NSError(domain: "ChatAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create Float32 audio format."])
    }

    // Connect player to mixer with Float32 format
    engine.connect(player, to: engine.mainMixerNode, format: floatFormat)

    let input = engine.inputNode
    let micFormat = input.outputFormat(forBus: 0)
    let converter = AVAudioConverter(from: micFormat, to: pcm16Format)

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
      guard let self, self.isRecording, !self.isPlayingAudio else { return }
      guard let converted = self.convertToPCM16Mono24k(buffer: buffer) else { return }
      self.continuation?.yield(converted)
    }

    engine.prepare()
    if !engine.isRunning {
      try engine.start()
    }

    // Start player after engine is running
    player.play()

    lock.withLock {
      self.inputConverter = converter
      self.inputFormat = pcm16Format
      self.outputFormat = floatFormat
    }
  }

  func teardown() {
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
  }

  func playPCM(_ pcm: Data) {
    let format: AVAudioFormat? = lock.withLock { outputFormat }
    guard let format else { return }

    let frameCount = pcm.count / 2 // Int16 = 2 bytes per sample
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
    buffer.frameLength = AVAudioFrameCount(frameCount)

    // Convert Int16 PCM to Float32 for playback
    pcm.withUnsafeBytes { raw in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
      guard let floatData = buffer.floatChannelData?[0] else { return }
      for i in 0..<frameCount {
        floatData[i] = Float(base[i]) / 32768.0
      }
    }

    // Track pending buffers for echo prevention
    lock.withLock {
      _pendingBuffers += 1
      _isPlayingAudio = true
    }

    // Use .dataPlayedBack to wait until audio actually finishes playing (not just consumed)
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      guard let self else { return }
      self.lock.withLock {
        self._pendingBuffers -= 1
        if self._pendingBuffers <= 0 {
          self._pendingBuffers = 0
          self._isPlayingAudio = false
        }
      }
    }
  }
  
  private func convertToPCM16Mono24k(buffer: AVAudioPCMBuffer) -> Data? {
    let (converter, format): (AVAudioConverter?, AVAudioFormat?) = lock.withLock {
      (inputConverter, inputFormat)
    }
    guard let converter, let format else { return nil }
    
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    
    var error: NSError?
    var didProvideInput = false
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      if didProvideInput {
        outStatus.pointee = .endOfStream
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return buffer
    }
    let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
    if error != nil || status == .error { return nil }

    guard out.frameLength > 0 else { return nil }

    // Debug: print frame counts occasionally
    // print("Converted \(buffer.frameLength) @ \(buffer.format.sampleRate)Hz -> \(out.frameLength) @ 24kHz")
    guard let ch = out.int16ChannelData else { return nil }
    let frames = Int(out.frameLength)
    return Data(bytes: ch[0], count: frames * MemoryLayout<Int16>.size)
  }
}

// MARK: - View Model

@MainActor
final class GrokVoiceViewModel: ObservableObject {
  enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
  }

  @Published var state: ConnectionState = .disconnected
  @Published var lastError: String = ""

  @Published var rawEvents: String = ""
  @Published var transcript: String = ""

  @Published var voice: String = "sal" // xAI voices: ara, rex, sal, eve, leo
  @Published var model: String = "" // optional; if empty, connect without model query param
  @Published var instructions: String = "You are a helpful voice assistant. Respond naturally and conversationally. Keep responses concise."

  @Published var isRecording: Bool = false
  @Published var useServerVAD: Bool = true // Server-side voice activity detection (auto turn detection)
  @Published var isSessionReady: Bool = false
  @Published var micLevel: Double = 0.0

  // Key handling (allowed persistence for functionality)
  let apiKey = SecureBytes()
  @Published var apiKeyStatus: String = "Key not loaded"

  private let service = GrokVoiceService()
  private let audio = AudioHandler()
  private var audioSendTask: Task<Void, Never>?
  private var bytesSentThisTurn: Int = 0
  private var didDetectSpeechThisTurn: Bool = false
  private var lastMeterUpdate: CFAbsoluteTime = 0

  /// Loads API key with precedence: ENV > Keychain.
  /// If found in ENV, auto-persists to keychain so Finder/Xcode launches work too.
  func bootstrapKey() {
    // Precedence: ENV (e.g. ~/.zshrc) > Keychain
    let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let envKey, !envKey.isEmpty {
      apiKey.set(utf8String: envKey)
      // Persist env key once so Finder/Xcode launches work too
      if (try? XAIKeychainStore.load()) == nil {
        try? XAIKeychainStore.save(envKey)
      }
      apiKeyStatus = "Key loaded (env)"
      return
    }

    // Try keychain silently
    if let stored = try? XAIKeychainStore.load(), !stored.isEmpty {
      apiKey.set(utf8String: stored)
      apiKeyStatus = "Key loaded (keychain)"
      return
    }

    apiKeyStatus = apiKey.isEmpty ? "Enter key or click Load" : "Key loaded"
  }

  /// Explicitly load key from keychain (user-initiated to avoid surprise auth dialogs).
  func loadKeyFromKeychain() {
    guard apiKey.isEmpty else {
      apiKeyStatus = "Key already loaded"
      return
    }
    do {
      if let stored = try XAIKeychainStore.load(), !stored.isEmpty {
        apiKey.set(utf8String: stored)
        apiKeyStatus = "Key loaded (keychain)"
      } else {
        apiKeyStatus = "No key in keychain"
      }
    } catch {
      apiKeyStatus = "Keychain access failed"
      lastError = error.localizedDescription
    }
  }

  func setKeyPersistently(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    apiKey.set(utf8String: trimmed)
    try? XAIKeychainStore.save(trimmed)
    apiKeyStatus = "Key saved"
  }

  func forgetKey() {
    apiKey.wipe()
    try? XAIKeychainStore.delete()
    apiKeyStatus = "Key not loaded"
  }

  func connect() {
    bootstrapKey()
    lastError = ""
    rawEvents = ""
    transcript = ""
    isSessionReady = false

    state = .connecting

    Task {
      do {
        try await ensureMicrophoneAccess()
        // Run audio config off main thread to prevent UI freeze
        try await configureAudioAsync()

        // Configure turn detection based on user preference
        let turnDetection: GrokVoiceService.SessionConfig.TurnDetection = useServerVAD
          ? .serverVAD(threshold: 0.3, prefixPaddingMs: 300, silenceDurationMs: 500)
          : .none
        
        try await service.connect(
          apiKey: apiKey,
          config: .init(
            model: model.isEmpty ? nil : model,
            voice: voice,
            instructions: instructions,
            turnDetection: turnDetection
          ),
          onSessionReady: { [weak self] in
            DispatchQueue.main.async { self?.isSessionReady = true }
          },
          onRawEvent: { [weak self] evt in
            DispatchQueue.main.async { self?.appendRaw(evt) }
          },
          onTextDelta: { [weak self] delta in
            DispatchQueue.main.async { self?.transcript.append(delta) }
          },
          onAudioDeltaPCM24k16: { [weak self] pcm in
            // Direct call - AudioHandler is thread-safe
            self?.audio.playPCM(pcm)
          },
          onError: { [weak self] err in
            DispatchQueue.main.async {
              self?.lastError = err
              self?.state = .error
              self?.isSessionReady = false
            }
          }
        )

        await MainActor.run { self.state = .connected }
      } catch {
        await MainActor.run {
          self.lastError = error.localizedDescription
          self.state = .error
          self.isSessionReady = false
        }
      }
    }
  }

  func disconnect() {
    stopRecording()
    service.disconnect()
    audio.teardown()
    state = .disconnected
  }

  func toggleRecording() {
    if isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  func sendText(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Show user's message in transcript
    transcript.append("\n👤 You: \(trimmed)\n")

    Task {
      do {
        try await service.sendUserText(trimmed, onRawEvent: { [weak self] evt in
          DispatchQueue.main.async { self?.appendRaw(evt) }
        })
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
      }
    }
  }

  // MARK: - Recording

  private func startRecording() {
    guard state == .connected else { return }
    guard isSessionReady else {
      lastError = "Session not ready yet. Wait for “session.updated”, then try Talk again."
      return
    }
    guard audio.continuation == nil else { return }

    isRecording = true
    audio.isRecording = true
    lastError = ""
    bytesSentThisTurn = 0
    didDetectSpeechThisTurn = false
    lastMeterUpdate = CFAbsoluteTimeGetCurrent()

    let stream = AsyncStream<Data> { continuation in
      self.audio.continuation = continuation
    }

    audioSendTask = Task { [weak self] in
      guard let self else { return }

      // Start each capture with a clean buffer (optional - don't fail if this errors)
      do {
        try await service.clearInputAudioBuffer(onRawEvent: { [weak self] evt in
          DispatchQueue.main.async { self?.appendRaw(evt) }
        })
      } catch {
        // Ignore clear buffer errors - just continue with recording
      }

      for await chunk in stream {
        do {
          bytesSentThisTurn += chunk.count
          let (peak, peakNorm) = Self.peakAmplitudePCM16(chunk)
          if peak > 0, peakNorm > 0.02 {
            didDetectSpeechThisTurn = true
          }
          let now = CFAbsoluteTimeGetCurrent()
          if now - lastMeterUpdate > 0.08 {
            lastMeterUpdate = now
            DispatchQueue.main.async { [weak self] in
              self?.micLevel = peakNorm
            }
          }
          try await service.appendInputAudioPCMBase64(chunk, onRawEvent: { [weak self] evt in
            DispatchQueue.main.async { self?.appendRaw(evt) }
          })
        } catch {
          await MainActor.run {
            self.lastError = "Connection lost: \(error.localizedDescription)"
            self.state = .error
          }
          break
        }
      }
    }
  }

  private func stopRecording() {
    guard isRecording else { return }
    isRecording = false
    audio.isRecording = false
    audio.continuation?.finish()
    audio.continuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil
    micLevel = 0.0

    // If we captured effectively no audio/speech, don't request a response (it will just greet).
    if bytesSentThisTurn < 12_000 || !didDetectSpeechThisTurn {
      lastError = "No speech detected. Check macOS input device/level, then try again."
      return
    }

    // Always commit when the user stops recording.
    // Server VAD can fail if the client stops sending audio before the server detects silence.
    Task { [weak self] in
      guard let self else { return }
      do {
        try await service.commitInputAudioAndRequestResponse(onRawEvent: { [weak self] evt in
          DispatchQueue.main.async { self?.appendRaw(evt) }
        })
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
      }
    }
  }

  private static func peakAmplitudePCM16(_ data: Data) -> (peak: Int, normalized: Double) {
    guard !data.isEmpty else { return (0, 0) }
    var peak = 0
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
      let count = data.count / 2
      for i in 0..<count {
        let v = Int(base[i])
        let a = v >= 0 ? v : -v
        if a > peak { peak = a }
      }
    }
    let norm = min(1.0, Double(peak) / 32768.0)
    return (peak, norm)
  }

  // MARK: - Audio setup

  /// Configures audio engine asynchronously to prevent UI freeze.
  private func configureAudioAsync() async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async { [audio] in
        do {
          try audio.configure()
          cont.resume()
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  private func ensureMicrophoneAccess() async throws {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized { return }
    if status == .denied || status == .restricted {
      throw NSError(domain: "ChatAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."])
    }

    try await withCheckedThrowingContinuation { cont in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
          cont.resume()
        } else {
          cont.resume(throwing: NSError(domain: "ChatAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."]))
        }
      }
    }
  }

  private func appendRaw(_ evt: String) {
    rawEvents.append(evt)
    rawEvents.append("\n")
  }
}

