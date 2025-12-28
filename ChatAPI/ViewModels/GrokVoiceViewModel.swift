import AVFoundation
import Combine
import Foundation

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

  @Published var voice: String = "Ara"
  @Published var model: String = "" // optional; if empty, connect without model query param
  @Published var instructions: String = ""

  @Published var isRecording: Bool = false

  // Key handling (allowed persistence for functionality)
  let apiKey = SecureBytes()
  @Published var apiKeyStatus: String = "Key not loaded"

  private let service = GrokVoiceService()

  // Audio I/O
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var inputConverter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?

  private var audioStreamContinuation: AsyncStream<Data>.Continuation?
  private var audioSendTask: Task<Void, Never>?

  /// Checks only environment variable on appear (no keychain access to avoid auth dialogs).
  func bootstrapKey() {
    // Only check environment variable - no keychain access to avoid repeated auth dialogs
    let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let envKey, !envKey.isEmpty {
      apiKey.set(utf8String: envKey)
      apiKeyStatus = "Key loaded (env)"
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
    guard SecureBytes.validateAPIKeyFormat(trimmed) else {
      lastError = "Invalid key format."
      return
    }
    apiKey.set(utf8String: trimmed)
    try? XAIKeychainStore.save(trimmed)
    apiKeyStatus = "Key loaded (keychain)"
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

    state = .connecting

    Task {
      do {
        try await ensureMicrophoneAccess()
        // Run audio config off main thread to prevent UI freeze
        try await configureAudioAsync()

        try await service.connect(
          apiKey: apiKey,
          config: .init(
            model: model.isEmpty ? nil : model,
            voice: voice,
            instructions: instructions
          ),
          onRawEvent: { [weak self] evt in
            Task { @MainActor in self?.appendRaw(evt) }
          },
          onTextDelta: { [weak self] delta in
            Task { @MainActor in self?.transcript.append(delta) }
          },
          onAudioDeltaPCM24k16: { [weak self] pcm in
            Task { @MainActor in self?.playPCM24kMono16(pcm) }
          },
          onError: { [weak self] err in
            Task { @MainActor in
              self?.lastError = err
              self?.state = .error
            }
          }
        )

        await MainActor.run { self.state = .connected }
      } catch {
        await MainActor.run {
          self.lastError = error.localizedDescription
          self.state = .error
        }
      }
    }
  }

  func disconnect() {
    stopRecording()
    service.disconnect()
    teardownAudio()
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
    Task {
      do {
        try await service.sendUserText(text, onRawEvent: { [weak self] evt in
          Task { @MainActor in self?.appendRaw(evt) }
        })
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
      }
    }
  }

  // MARK: - Recording

  private func startRecording() {
    guard state == .connected else { return }
    guard audioStreamContinuation == nil else { return }

    isRecording = true
    lastError = ""

    let stream = AsyncStream<Data> { continuation in
      self.audioStreamContinuation = continuation
    }

    audioSendTask = Task { [weak self] in
      guard let self else { return }
      for await chunk in stream {
        do {
          try await service.appendInputAudioPCMBase64(chunk, onRawEvent: { [weak self] evt in
            Task { @MainActor in self?.appendRaw(evt) }
          })
        } catch {
          await MainActor.run { self.lastError = error.localizedDescription }
          break
        }
      }
    }
  }

  private func stopRecording() {
    guard isRecording else { return }
    isRecording = false
    audioStreamContinuation?.finish()
    audioStreamContinuation = nil
    audioSendTask?.cancel()
    audioSendTask = nil

    Task {
      do {
        try await service.commitInputAudioAndRequestResponse(onRawEvent: { [weak self] evt in
          Task { @MainActor in self?.appendRaw(evt) }
        })
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
      }
    }
  }

  // MARK: - Audio setup

  /// Configures audio engine asynchronously to prevent UI freeze.
  private func configureAudioAsync() async throws {
    // Run blocking audio engine operations off the main thread
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        do {
          if self.engine.attachedNodes.contains(self.player) == false {
            self.engine.attach(self.player)
          }

          let desired = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)
          guard let desired else {
            throw NSError(domain: "ChatAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format."])
          }

          self.engine.connect(self.player, to: self.engine.mainMixerNode, format: desired)
          self.player.play()

          let input = self.engine.inputNode
          let inputFormat = input.outputFormat(forBus: 0)
          let converter = AVAudioConverter(from: inputFormat, to: desired)

          input.removeTap(onBus: 0)
          input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task { @MainActor in
              guard self.isRecording else { return }
              guard let converted = self.convertToPCM16Mono24k(buffer: buffer) else { return }
              self.audioStreamContinuation?.yield(converted)
            }
          }

          self.engine.prepare()
          if !self.engine.isRunning {
            try self.engine.start()
          }

          // Store converter and format on main thread
          DispatchQueue.main.async {
            self.inputConverter = converter
            self.targetFormat = desired
            cont.resume()
          }
        } catch {
          DispatchQueue.main.async {
            cont.resume(throwing: error)
          }
        }
      }
    }
  }

  private func ensureMicrophoneAccess() async throws {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized { return }
    if status == .denied || status == .restricted {
      throw NSError(domain: "OpenScienceNative", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."])
    }

    try await withCheckedThrowingContinuation { cont in
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
          cont.resume()
        } else {
          cont.resume(throwing: NSError(domain: "OpenScienceNative", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied."]))
        }
      }
    }
  }

  private func teardownAudio() {
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
  }

  private func convertToPCM16Mono24k(buffer: AVAudioPCMBuffer) -> Data? {
    guard let inputConverter, let targetFormat else { return nil }

    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (24_000.0 / buffer.format.sampleRate) + 32)
    guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    inputConverter.convert(to: out, error: &error, withInputFrom: inputBlock)
    if error != nil { return nil }

    out.frameLength = out.frameCapacity

    guard let ch = out.int16ChannelData else { return nil }
    let frames = Int(out.frameLength)
    let byteCount = frames * MemoryLayout<Int16>.size
    return Data(bytes: ch[0], count: byteCount)
  }

  private func playPCM24kMono16(_ pcm: Data) {
    guard let targetFormat else { return }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else { return }
    buffer.frameLength = buffer.frameCapacity

    pcm.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      let dst = buffer.int16ChannelData![0]
      memcpy(dst, base, pcm.count)
    }

    player.scheduleBuffer(buffer, completionHandler: nil)
  }

  private func appendRaw(_ evt: String) {
    rawEvents.append(evt)
    rawEvents.append("\n")
  }
}


