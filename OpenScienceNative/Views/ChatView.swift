import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

            PromptBarWithAttachments()
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

            PromptBarWithAttachments()
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

  // MARK: - Prompt Bar with Attachments

  @ViewBuilder
  private func PromptBarWithAttachments() -> some View {
    VStack(spacing: 8) {
      // Attachment preview chips
      if !chat.pendingAttachments.isEmpty {
        AttachmentPreviewBar()
      }

      // Main prompt bar
      PromptBar()
    }
    .frame(maxWidth: 860)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func AttachmentPreviewBar() -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(chat.pendingAttachments) { attachment in
          AttachmentChip(attachment: attachment) {
            chat.removeAttachment(attachment.id)
          }
        }
      }
      .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func PromptBar() -> some View {
    HStack(spacing: 10) {
      // Attachment button with dropdown menu
      AttachmentMenu()

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
      .disabled(!chat.isSending && chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.pendingAttachments.isEmpty)
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
  }

  // MARK: - Attachment Menu

  @ViewBuilder
  private func AttachmentMenu() -> some View {
    Menu {
      Button {
        openImagePicker()
      } label: {
        Label("Upload Image", systemImage: "photo")
      }

      Button {
        openFilePicker()
      } label: {
        Label("Upload File", systemImage: "doc")
      }
    } label: {
      Image(systemName: "plus.circle.fill")
        .font(.system(size: 20))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Add attachment")
  }

  // MARK: - File Pickers

  private func openImagePicker() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = Attachment.imageUTTypes
    panel.message = "Select images to attach"
    panel.prompt = "Attach"

    panel.begin { response in
      if response == .OK {
        for url in panel.urls {
          chat.addAttachment(from: url)
        }
      }
    }
  }

  private func openFilePicker() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.item] // All file types
    panel.message = "Select files to attach"
    panel.prompt = "Attach"

    panel.begin { response in
      if response == .OK {
        for url in panel.urls {
          chat.addAttachment(from: url)
        }
      }
    }
  }
}

// MARK: - Attachment Chip View

private struct AttachmentChip: View {
  let attachment: Attachment
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      // Thumbnail or icon
      if attachment.isImage, let nsImage = NSImage(data: attachment.data) {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 24, height: 24)
          .clipShape(RoundedRectangle(cornerRadius: 4))
      } else {
        Image(systemName: iconForMimeType(attachment.mimeType))
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
      }

      // Filename
      Text(attachment.filename)
        .font(.system(size: 11))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 120)

      // Size
      Text(attachment.formattedSize)
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)

      // Remove button
      Button {
        onRemove()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    )
  }

  private func iconForMimeType(_ mimeType: String) -> String {
    if mimeType.hasPrefix("image/") {
      return "photo"
    } else if mimeType.hasPrefix("video/") {
      return "video"
    } else if mimeType.hasPrefix("audio/") {
      return "waveform"
    } else if mimeType.contains("pdf") {
      return "doc.richtext"
    } else if mimeType.contains("json") || mimeType.contains("javascript") {
      return "curlybraces"
    } else if mimeType.contains("text") || mimeType.contains("xml") {
      return "doc.text"
    } else if mimeType.contains("zip") || mimeType.contains("compressed") {
      return "doc.zipper"
    } else {
      return "doc"
    }
  }
}


