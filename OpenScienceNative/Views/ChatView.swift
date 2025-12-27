import SwiftUI

struct ChatView: View {
  @EnvironmentObject private var chat: ChatViewModel

  var body: some View {
    HStack(spacing: 0) {
      ZStack {
        StarfieldBackgroundView()

        if chat.messages.isEmpty {
          VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 10) {
              Text("OpenScience Native")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
              Text("Zero-context scientific auditing via OpenRouter")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }

            PromptBar()
              .padding(.horizontal, 24)

            Spacer()
          }
        } else {
          VStack(spacing: 0) {
            Spacer(minLength: 24)

            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 10) {
                  ForEach(chat.messages) { msg in
                    MessageBubbleView(message: msg)
                      .id(msg.id)
                  }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: 900, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
              }
              .onChange(of: chat.messages.last?.id) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                  proxy.scrollTo(newID, anchor: .bottom)
                }
              }
            }

            PromptBar()
              .padding(.horizontal, 24)
              .padding(.vertical, 18)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if chat.isInspectorPresented {
        Divider()
        LabSettingsView()
          .frame(width: 360)
      }
    }
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          chat.isInspectorPresented.toggle()
        } label: {
          Image(systemName: "sidebar.right")
        }
        .help("Toggle Inspector")
      }
    }
  }

  @ViewBuilder
  private func PromptBar() -> some View {
    HStack(spacing: 10) {
      TextField("What do you want to know?", text: $chat.inputText, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .font(.system(size: 15))
        .foregroundStyle(.primary)
        .padding(.vertical, 10)
        .onSubmit {
          chat.send()
        }

      Divider()
        .opacity(0.35)

      Text(chat.selectedModelID)
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Button {
        if chat.isSending {
          chat.stop()
        } else {
          chat.send()
        }
      } label: {
        Image(systemName: chat.isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
          .font(.system(size: 18))
      }
      .buttonStyle(.plain)
      .disabled(!chat.isSending && chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    )
    .frame(maxWidth: 860)
    .frame(maxWidth: .infinity)
  }
}


