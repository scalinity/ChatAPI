import SwiftUI

struct GrokVoiceAgentSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var vm = GrokVoiceViewModel()

  @State private var keyDraft: String = ""
  @State private var userText: String = ""

  private let voices = ["Ara", "Rex", "Sal", "Eve", "Leo"]

  var body: some View {
    VStack(spacing: 0) {
      // Fixed header bar - always visible
      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")

        Text("Grok Voice Agent")
          .font(.system(size: 15, weight: .semibold))
          .padding(.leading, 8)

        Spacer()

        Button("Done") {
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.bar)

      Divider()

      // Scrollable content
      ScrollView {
        VStack(spacing: 12) {
          HStack(alignment: .top, spacing: 12) {
            leftControls
            rightStatus
          }

          Divider().opacity(0.35)

          transcriptArea

          Divider().opacity(0.35)

          rawArea
        }
        .padding(16)
      }
    }
    .frame(minWidth: 980, minHeight: 720)
    .onAppear { vm.bootstrapKey() }
    .onDisappear { vm.disconnect() }
    .onExitCommand { dismiss() }
  }

  private var leftControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      GroupBox("xAI API Key (Keychain)") {
        VStack(alignment: .leading, spacing: 8) {
          Text(vm.apiKeyStatus)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

          HStack {
            SecureField("XAI_API_KEY", text: $keyDraft)
              .textFieldStyle(.roundedBorder)

            Button("Set") {
              vm.setKeyPersistently(keyDraft)
              keyDraft = ""
            }
            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Load") {
              vm.loadKeyFromKeychain()
            }
            .help("Load saved key from Keychain (may prompt for password)")

            Button("Forget", role: .destructive) {
              vm.forgetKey()
            }
          }
        }
      }

      GroupBox("Session") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Voice")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $vm.voice) {
              ForEach(voices, id: \.self) { v in
                Text(v).tag(v)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
          }

          HStack {
            Text("Model (optional)")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer()
          }
          TextField("Leave empty unless required (appends ?model=...)", text: $vm.model)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))

          Text("Instructions")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          TextEditor(text: $vm.instructions)
            .font(.system(size: 12))
            .frame(minHeight: 90)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
            .help("Visible, explicit instructions; not hidden.")
        }
      }

      GroupBox("Controls") {
        HStack(spacing: 10) {
          Button(vm.state == .connected ? "Disconnect" : "Connect") {
            if vm.state == .connected {
              vm.disconnect()
            } else {
              vm.connect()
            }
          }
          .buttonStyle(.borderedProminent)

          Button {
            vm.toggleRecording()
          } label: {
            HStack(spacing: 8) {
              Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
              Text(vm.isRecording ? "Stop" : "Talk")
            }
          }
          .buttonStyle(.bordered)
          .disabled(vm.state != .connected)

          Spacer()
        }

        HStack(spacing: 10) {
          TextField("Send text to voice agent…", text: $userText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...3)
            .onSubmit {
              vm.sendText(userText)
              userText = ""
            }

          Button("Send") {
            vm.sendText(userText)
            userText = ""
          }
          .buttonStyle(.bordered)
          .disabled(userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.state != .connected)
        }
      }
    }
    .frame(maxWidth: 520)
  }

  private var rightStatus: some View {
    VStack(alignment: .leading, spacing: 10) {
      GroupBox("Status") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("State")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Text(vm.state.rawValue)
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          if !vm.lastError.isEmpty {
            Text("Error")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
            Text(vm.lastError)
              .font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
              .foregroundStyle(.red.opacity(0.85))
          }

          Text("Privacy")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          Text("No audio is written to disk. Streaming buffers exist only in RAM.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var transcriptArea: some View {
    GroupBox("Transcript") {
      ScrollView {
        Text(vm.transcript.isEmpty ? "—" : vm.transcript)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(minHeight: 220)
      .background(.black.opacity(0.12))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }
  }

  private var rawArea: some View {
    GroupBox("Raw Events (WebSocket)") {
      ScrollView {
        Text(vm.rawEvents.isEmpty ? "—" : vm.rawEvents)
          .font(.system(size: 10, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(minHeight: 220)
      .background(.black.opacity(0.12))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }
  }
}


