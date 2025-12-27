import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatView: View {
  @EnvironmentObject private var chat: ChatViewModel
  @State private var isDropTargeted: Bool = false
  @State private var isToolsPopoverPresented: Bool = false
  @State private var isModelPopoverPresented: Bool = false
  @State private var modelQuery: String = ""
  @State private var activeToolSheet: ToolSheet?

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
      .sheet(item: $activeToolSheet) { sheet in
        switch sheet {
        case .canvas:
          CanvasToolSheet()
            .environmentObject(chat)
        case .images:
          ImageToolSheet()
            .environmentObject(chat)
        case .video:
          VideoToolSheet()
            .environmentObject(chat)
        case .agentLabs:
          AgentLabsToolSheet()
            .environmentObject(chat)
        }
      }

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
      GeminiStylePromptBar()
    }
    .frame(maxWidth: 860)
    .frame(maxWidth: .infinity)
    .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isDropTargeted) { providers in
      handleDrop(providers: providers)
    }
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
  private func GeminiStylePromptBar() -> some View {
    VStack(spacing: 0) {
      // Top: input area
      TextField("Ask \(shortModelName(chat.selectedModelID))", text: $chat.inputText, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 16))
        .foregroundStyle(.primary)
        .lineLimit(1...8)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .onSubmit {
          chat.send()
        }

      // Bottom: actions row (Gemini-like)
      HStack(spacing: 12) {
        PlusMenuButton()

        ToolsButton()

        Spacer()

        ModelButton()

        SendButton()
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 12)
    }
    .background(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .fill(Color.black.opacity(0.32))
        .background(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(isDropTargeted ? Color.accentColor.opacity(0.65) : .white.opacity(0.08), lineWidth: isDropTargeted ? 2 : 1)
    )
  }

  // MARK: - Attachment Menu

  @ViewBuilder
  private func PlusMenuButton() -> some View {
    Menu {
      Button {
        openImagePicker()
      } label: {
        Label("Add photos", systemImage: "photo")
      }

      Button {
        openFilePicker()
      } label: {
        Label("Add files", systemImage: "doc")
      }

      Divider()

      Button {
        chat.resetSession()
      } label: {
        Label("New chat", systemImage: "plus.square.on.square")
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 30, height: 30)
        .background(Circle().fill(.white.opacity(0.08)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Add")
  }

  // MARK: - Tools

  private func ToolsButton() -> some View {
    Button {
      isToolsPopoverPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 13, weight: .semibold))
        Text("Tools")
          .font(.system(size: 13, weight: .semibold))
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.white.opacity(0.06))
      )
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isToolsPopoverPresented, arrowEdge: .bottom) {
      ToolsPopover(
        modelID: chat.selectedModelID,
        connectorCount: chat.mcpConnectors.count,
        onSelect: { action in
          isToolsPopoverPresented = false
          handleToolSelection(action)
        }
      )
      .environmentObject(chat)
      .frame(width: 280)
      .padding(12)
    }
  }

  private func handleToolSelection(_ action: ToolAction) {
    switch action {
    case .deepResearch:
      applyPreset(.deepResearch)
    case .guidedLearning:
      applyPreset(.guidedLearning)
    case .deepThink:
      applyPreset(.deepThink)
    case .createImages:
      activeToolSheet = .images
    case .createVideo:
      activeToolSheet = .video
    case .canvas:
      activeToolSheet = .canvas
    case .agentLabs:
      activeToolSheet = .agentLabs
    }
  }

  private func applyPreset(_ preset: ToolAction) {
    // Visible, explicit preset changes (no hidden prompts).
    switch preset {
    case .deepResearch:
      chat.settings.reasoningEnabled = true
      chat.settings.reasoningEffort = "xhigh"
      chat.settings.temperature = 0.2
      chat.settings.topP = 0.95
      chat.systemPromptText =
        "ROLE: Scientific research engine.\n" +
        "CONSTRAINTS: Prioritize correctness, completeness, and theoretical depth.\n" +
        "OUTPUT: Cite assumptions, show uncertainty, and separate hypotheses from conclusions."
    case .guidedLearning:
      chat.settings.reasoningEnabled = true
      chat.settings.reasoningEffort = "high"
      chat.settings.temperature = 0.7
      chat.settings.topP = 0.95
      chat.systemPromptText =
        "ROLE: Tutor.\n" +
        "OBJECTIVE: Teach by asking short, targeted questions.\n" +
        "STYLE: Step-by-step, check understanding, no hidden assumptions."
    case .deepThink:
      chat.settings.reasoningEnabled = true
      chat.settings.reasoningEffort = "xhigh"
      chat.settings.temperature = 0.0
      chat.settings.topP = 1.0
      chat.systemPromptText =
        "ROLE: Deterministic reasoning engine.\n" +
        "OBJECTIVE: Provide rigorous reasoning, avoid stylistic filler.\n" +
        "OUTPUT: Clearly mark uncertainties and edge cases."
    default:
      break
    }
  }

  // MARK: - Model Picker (popover)

  private func ModelButton() -> some View {
    Button {
      isModelPopoverPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Text(shortModelName(chat.selectedModelID))
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.white.opacity(0.06))
      )
    }
    .buttonStyle(.plain)
    .popover(isPresented: $isModelPopoverPresented, arrowEdge: .bottom) {
      ModelPickerPopover(
        query: $modelQuery,
        models: chat.sortedModels,
        selectedID: $chat.selectedModelID,
        onClose: { isModelPopoverPresented = false }
      )
      .frame(width: 380, height: 420)
      .padding(12)
    }
  }

  private func SendButton() -> some View {
    Button {
      if chat.isSending {
        chat.stop()
      } else {
        chat.send()
      }
    } label: {
      Image(systemName: chat.isSending ? "stop.fill" : "arrow.up")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 34, height: 34)
        .background(Circle().fill(.white.opacity(0.10)))
    }
    .buttonStyle(.plain)
    .disabled(!chat.isSending && chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.pendingAttachments.isEmpty)
    .help(chat.isSending ? "Stop" : "Send")
  }

  private func shortModelName(_ modelID: String) -> String {
    if let slash = modelID.lastIndex(of: "/") {
      return String(modelID[modelID.index(after: slash)...])
    }
    return modelID
  }

  // MARK: - Drag & Drop

  private func handleDrop(providers: [NSItemProvider]) -> Bool {
    var handled = false

    for provider in providers {
      if provider.canLoadObject(ofClass: URL.self) {
        handled = true
        _ = provider.loadObject(ofClass: URL.self) { object, _ in
          guard let url = object else { return }
          Task { @MainActor in
            chat.addAttachment(from: url)
          }
        }
        continue
      }

      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        handled = true
        let preferred = [
          UTType.png.identifier,
          UTType.jpeg.identifier,
          UTType.tiff.identifier,
          UTType.image.identifier,
        ]
        let typeID = preferred.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) ?? UTType.image.identifier
        provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
          guard let data else { return }
          let ut = UTType(typeID)
          let ext = ut?.preferredFilenameExtension ?? "png"
          let mime = ut?.preferredMIMEType ?? "image/\(ext)"
          let attachment = Attachment(filename: "dropped.\(ext)", mimeType: mime, data: data)
          Task { @MainActor in
            chat.addAttachment(attachment)
          }
        }
      }
    }

    return handled
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

// MARK: - Tool Menu Types

private enum ToolAction: String, CaseIterable, Identifiable {
  case deepResearch
  case createVideo
  case createImages
  case canvas
  case guidedLearning
  case deepThink
  case agentLabs

  var id: String { rawValue }
}

private enum ToolSheet: String, Identifiable {
  case canvas
  case images
  case video
  case agentLabs

  var id: String { rawValue }
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

// MARK: - Tools Popover

private struct ToolsPopover: View {
  @EnvironmentObject private var chat: ChatViewModel
  let modelID: String
  let connectorCount: Int
  let onSelect: (ToolAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Tools")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      toolRow(.deepResearch, icon: "magnifyingglass")
      toolRow(.canvas, icon: "square.and.pencil")

      if isVideoCapable(modelID) {
        toolRow(.createVideo, icon: "video")
      } else {
        toolRow(.createVideo, icon: "video", enabled: false, hint: "Not available for this model")
      }

      if isImageCapable(modelID) {
        toolRow(.createImages, icon: "photo")
      } else {
        toolRow(.createImages, icon: "photo", enabled: false, hint: "Not available for this model")
      }

      Divider().opacity(0.35)

      toolRow(.guidedLearning, icon: "book")
      toolRow(.deepThink, icon: "brain")

      Divider().opacity(0.35)

      HStack {
        toolRow(.agentLabs, icon: "flask", badge: "Labs")
        Spacer()
      }

      Divider().opacity(0.35)

      Text("MCP Connectors")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      if connectorCount == 0 {
        Text("No connectors configured")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      } else {
        ForEach(chat.mcpConnectors.prefix(3)) { c in
          HStack(spacing: 8) {
            Circle()
              .fill(color(for: c.status))
              .frame(width: 7, height: 7)
            Text(c.name)
              .font(.system(size: 12, weight: .medium))
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer()
            Text("\(c.tools.count)")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
        }
      }

      Button {
        onSelect(.agentLabs)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "slider.horizontal.3")
          Text("Manage connectors…")
          Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
      }
      .buttonStyle(.plain)
    }
  }

  @ViewBuilder
  private func toolRow(_ action: ToolAction, icon: String, enabled: Bool = true, hint: String? = nil, badge: String? = nil) -> some View {
    Button {
      onSelect(action)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .frame(width: 18)

        Text(title(for: action))
          .font(.system(size: 13, weight: .medium))

        Spacer()

        if let badge {
          Text(badge)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.10)))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1.0 : 0.45)
    .help(hint ?? "")
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(.white.opacity(0.04))
    )
  }

  private func title(for action: ToolAction) -> String {
    switch action {
    case .deepResearch: return "Deep Research"
    case .createVideo: return "Create videos"
    case .createImages: return "Create images"
    case .canvas: return "Canvas"
    case .guidedLearning: return "Guided learning"
    case .deepThink: return "Deep Think"
    case .agentLabs: return "Agent (Labs)"
    }
  }

  private func isImageCapable(_ modelID: String) -> Bool {
    let id = modelID.lowercased()
    return id.contains("gpt") || id.contains("gemini") || id.contains("claude") || id.contains("vision") || id.contains("image") || id.contains("flux") || id.contains("sdxl") || id.contains("dall")
  }

  private func isVideoCapable(_ modelID: String) -> Bool {
    let id = modelID.lowercased()
    return id.contains("gpt") || id.contains("gemini") || id.contains("veo") || id.contains("sora") || id.contains("video") || id.contains("luma")
  }

  private func color(for status: MCPConnector.Status) -> Color {
    switch status {
    case .disconnected: return .secondary.opacity(0.7)
    case .connecting: return .yellow.opacity(0.9)
    case .connected: return .green.opacity(0.9)
    case .error: return .red.opacity(0.9)
    }
  }
}

// MARK: - Model Picker Popover

private struct ModelPickerPopover: View {
  @Binding var query: String
  let models: [OpenRouterModel]
  @Binding var selectedID: String
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      header
      searchField
      resultsList
    }
  }

  private var header: some View {
    HStack {
      Text("Select Model")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Button("Done") { onClose() }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
  }

  private var searchField: some View {
    TextField("Search", text: $query)
      .textFieldStyle(.roundedBorder)
  }

  private var resultsList: some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(Array(filtered.prefix(250)), id: \.id) { model in
          ModelRow(
            model: model,
            isSelected: model.id == selectedID,
            onSelect: {
              selectedID = model.id
              onClose()
            }
          )
        }
      }
    }
  }

  private var filtered: [OpenRouterModel] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return models }
    return models.filter { $0.id.localizedCaseInsensitiveContains(q) || ($0.name?.localizedCaseInsensitiveContains(q) ?? false) }
  }
}

private struct ModelRow: View {
  let model: OpenRouterModel
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.id)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
          if let context = model.context_length {
            Text("Context: \(context)")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.18) : .white.opacity(0.04))
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Tool Sheets

private final class ToolRunner: ObservableObject {
  @Published var output: String = ""
  @Published var raw: String = ""
  @Published var error: String = ""
  @Published var isRunning: Bool = false

  private let service = OpenRouterService()
  private var task: Task<Void, Never>?

  func stop() {
    task?.cancel()
    task = nil
    isRunning = false
  }

  func run(
    apiKey: SecureBytes,
    model: String,
    systemPrompt: String?,
    prompt: String,
    attachments: [Attachment],
    temperature: Double,
    topP: Double,
    frequencyPenalty: Double,
    presencePenalty: Double,
    reasoningEnabled: Bool,
    reasoningEffort: String
  ) {
    stop()
    output = ""
    raw = ""
    error = ""
    isRunning = true

    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await service.sendMessage(
          apiKey: apiKey,
          model: model,
          systemPrompt: systemPrompt,
          isContextFree: true,
          history: [],
          currentUserContent: prompt,
          currentAttachments: attachments,
          temperature: temperature,
          topP: topP,
          frequencyPenalty: frequencyPenalty,
          presencePenalty: presencePenalty,
          reasoningEnabled: reasoningEnabled,
          reasoningEffort: reasoningEffort,
          onRawEvent: { evt in
            Task { @MainActor in
              self.raw.append(evt)
              self.raw.append("\n")
            }
          },
          onAssistantDelta: { delta in
            Task { @MainActor in
              self.output.append(delta)
            }
          }
        )
        await MainActor.run { self.isRunning = false }
      } catch is CancellationError {
        await MainActor.run { self.isRunning = false }
      } catch {
        await MainActor.run {
          self.error = error.localizedDescription
          self.isRunning = false
        }
      }
    }
  }
}

private struct CanvasToolSheet: View {
  @EnvironmentObject private var chat: ChatViewModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var runner = ToolRunner()

  @State private var code: String = ""
  @State private var question: String = ""

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Canvas")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Code")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          TextEditor(text: $code)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Question")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          TextEditor(text: $question)
            .font(.system(size: 12))
            .frame(minHeight: 120)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))

          HStack {
            Button(runner.isRunning ? "Stop" : "Run") {
              if runner.isRunning {
                runner.stop()
              } else {
                runner.run(
                  apiKey: chat.apiKey,
                  model: chat.selectedModelID,
                  systemPrompt: chat.systemPromptText,
                  prompt: canvasPrompt(code: code, question: question),
                  attachments: [],
                  temperature: chat.settings.temperature,
                  topP: chat.settings.topP,
                  frequencyPenalty: chat.settings.frequencyPenalty,
                  presencePenalty: chat.settings.presencePenalty,
                  reasoningEnabled: chat.settings.reasoningEnabled,
                  reasoningEffort: chat.settings.reasoningEffort
                )
              }
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Button("Send to Chat") {
              chat.inputText = canvasPrompt(code: code, question: question)
              dismiss()
            }
            .buttonStyle(.bordered)
          }
        }
      }

      Divider().opacity(0.35)

      VStack(alignment: .leading, spacing: 8) {
        Text("Output (stateless run)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        ScrollView {
          Text(runner.output.isEmpty ? "—" : runner.output)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(minHeight: 200)
        .background(.black.opacity(0.15))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))

        if !runner.error.isEmpty {
          Text("Error")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          Text(runner.error)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(16)
    .frame(minWidth: 900, minHeight: 650)
  }

  private func canvasPrompt(code: String, question: String) -> String {
    let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedQ = question.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedCode.isEmpty {
      return trimmedQ
    }
    return """
    \(trimmedQ)

    ```text
    \(trimmedCode)
    ```
    """
  }
}

private struct ImageToolSheet: View {
  @EnvironmentObject private var chat: ChatViewModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var runner = ToolRunner()
  @State private var prompt: String = ""
  @State private var attachments: [Attachment] = []

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Create images")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }
      }

      TextField("Describe the image you want…", text: $prompt, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...6)

      HStack {
        Button("Use current attachments") {
          attachments = chat.pendingAttachments
        }
        .buttonStyle(.bordered)

        Button(runner.isRunning ? "Stop" : "Generate") {
          if runner.isRunning {
            runner.stop()
          } else {
            runner.run(
              apiKey: chat.apiKey,
              model: chat.selectedModelID,
              systemPrompt: chat.systemPromptText,
              prompt: prompt,
              attachments: attachments,
              temperature: chat.settings.temperature,
              topP: chat.settings.topP,
              frequencyPenalty: chat.settings.frequencyPenalty,
              presencePenalty: chat.settings.presencePenalty,
              reasoningEnabled: chat.settings.reasoningEnabled,
              reasoningEffort: chat.settings.reasoningEffort
            )
          }
        }
        .buttonStyle(.borderedProminent)

        Spacer()

        Text("Stateless run")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      if !detectedImages.isEmpty || !detectedImageLinks.isEmpty {
        ImageResultsStrip(images: detectedImages, links: detectedImageLinks)
      }

      Divider().opacity(0.35)

      ToolOutputView(output: runner.output, raw: runner.raw, error: runner.error)
    }
    .padding(16)
    .frame(minWidth: 850, minHeight: 620)
  }

  private var detectedImages: [NSImage] {
    extractDataURLImages(from: runner.raw + "\n" + runner.output, limit: 6)
  }

  private var detectedImageLinks: [URL] {
    extractLinks(from: runner.raw + "\n" + runner.output)
      .filter { url in
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp"].contains(ext)
      }
      .prefix(6)
      .map { $0 }
  }
}

private struct VideoToolSheet: View {
  @EnvironmentObject private var chat: ChatViewModel
  @Environment(\.dismiss) private var dismiss
  @StateObject private var runner = ToolRunner()
  @State private var prompt: String = ""

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Create videos")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }
      }

      TextField("Describe the video you want…", text: $prompt, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...6)

      HStack {
        Button(runner.isRunning ? "Stop" : "Generate") {
          if runner.isRunning {
            runner.stop()
          } else {
            runner.run(
              apiKey: chat.apiKey,
              model: chat.selectedModelID,
              systemPrompt: chat.systemPromptText,
              prompt: prompt,
              attachments: [],
              temperature: chat.settings.temperature,
              topP: chat.settings.topP,
              frequencyPenalty: chat.settings.frequencyPenalty,
              presencePenalty: chat.settings.presencePenalty,
              reasoningEnabled: chat.settings.reasoningEnabled,
              reasoningEffort: chat.settings.reasoningEffort
            )
          }
        }
        .buttonStyle(.borderedProminent)

        Spacer()

        Text("Stateless run")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      Divider().opacity(0.35)

      if !detectedVideoLinks.isEmpty {
        DetectedLinksView(title: "Detected video links", links: detectedVideoLinks)
      }

      ToolOutputView(output: runner.output, raw: runner.raw, error: runner.error)
    }
    .padding(16)
    .frame(minWidth: 850, minHeight: 620)
  }

  private var detectedVideoLinks: [URL] {
    extractLinks(from: runner.raw + "\n" + runner.output)
      .filter { url in
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "webm", "m3u8"].contains(ext) || url.absoluteString.lowercased().contains("video")
      }
      .prefix(8)
      .map { $0 }
  }
}

private struct AgentLabsToolSheet: View {
  @EnvironmentObject private var chat: ChatViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var name: String = ""
  @State private var endpoint: String = ""

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Agent Labs (MCP Connectors)")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Button("Close") { dismiss() }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Add connector (HTTP JSON-RPC)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        HStack {
          TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)
          TextField("Endpoint URL (https://...)", text: $endpoint)
            .textFieldStyle(.roundedBorder)
          Button("Add") {
            chat.addMCPConnector(name: name, endpoint: endpoint)
            name = ""
            endpoint = ""
          }
          .buttonStyle(.borderedProminent)
        }
      }

      Divider().opacity(0.35)

      if chat.mcpConnectors.isEmpty {
        Text("No connectors. Add one to list tools via `tools/list`.")
          .foregroundStyle(.secondary)
        Spacer()
      } else {
        List {
          ForEach(chat.mcpConnectors) { c in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(c.name)
                  .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(c.status.rawValue)
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundStyle(.secondary)
              }

              Text(c.endpoint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

              HStack(spacing: 8) {
                Button("List tools") {
                  chat.refreshMCPTools(for: c.id)
                }
                .buttonStyle(.bordered)

                Button("Remove", role: .destructive) {
                  chat.removeMCPConnector(c.id)
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("\(c.tools.count) tool(s)")
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
              }

              if let err = c.lastError, !err.isEmpty {
                Text(err)
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundStyle(.red.opacity(0.85))
                  .textSelection(.enabled)
              }

              if !c.tools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                  ForEach(c.tools) { t in
                    VStack(alignment: .leading, spacing: 2) {
                      Text(t.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                      if let desc = t.description, !desc.isEmpty {
                        Text(desc)
                          .font(.system(size: 11))
                          .foregroundStyle(.secondary)
                      }
                    }
                    .padding(.vertical, 2)
                  }
                }
              }

              if let raw = c.lastRawResponse, !raw.isEmpty {
                DisclosureGroup("Raw JSON") {
                  ScrollView {
                    Text(raw)
                      .font(.system(size: 10, design: .monospaced))
                      .textSelection(.enabled)
                      .frame(maxWidth: .infinity, alignment: .leading)
                      .padding(8)
                  }
                  .frame(minHeight: 120)
                  .background(.black.opacity(0.12))
                  .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
                }
              }
            }
            .padding(.vertical, 6)
          }
        }
      }
    }
    .padding(16)
    .frame(minWidth: 900, minHeight: 650)
  }
}

private struct ToolOutputView: View {
  let output: String
  let raw: String
  let error: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Output")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        Text(output.isEmpty ? "—" : output)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .frame(minHeight: 220)
      .background(.black.opacity(0.15))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))

      if !error.isEmpty {
        Text("Error")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(error)
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
      }

      DisclosureGroup("Raw JSON / SSE Transcript") {
        ScrollView {
          Text(raw.isEmpty ? "—" : raw)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(minHeight: 140)
        .background(.black.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
      }
    }
  }
}

// MARK: - AppKit helpers

private extension NSImage {
  func pngData() -> Data? {
    guard let tiff = tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
  }
}

// MARK: - Result helpers (data URLs + link detection)

private func extractLinks(from text: String) -> [URL] {
  guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
    return []
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  return detector
    .matches(in: text, options: [], range: range)
    .compactMap { $0.url }
}

private func extractDataURLImages(from text: String, limit: Int) -> [NSImage] {
  guard limit > 0 else { return [] }
  var images: [NSImage] = []
  var searchStart = text.startIndex

  while images.count < limit, let start = text.range(of: "data:image", range: searchStart..<text.endIndex)?.lowerBound {
    // Find end by scanning until a terminator (quote, whitespace, or closing paren)
    var end = start
    while end < text.endIndex {
      let ch = text[end]
      if ch == "\"" || ch == "'" || ch == ")" || ch == " " || ch == "\n" || ch == "\r" || ch == "\t" {
        break
      }
      end = text.index(after: end)
    }
    let candidate = String(text[start..<end])
    if let img = decodeDataURLImage(candidate) {
      images.append(img)
    }
    searchStart = end
  }
  return images
}

private func decodeDataURLImage(_ dataURL: String) -> NSImage? {
  guard let commaRange = dataURL.range(of: "base64,") else { return nil }
  let b64 = String(dataURL[commaRange.upperBound...])
  guard let data = Data(base64Encoded: b64) else { return nil }
  return NSImage(data: data)
}

private struct ImageResultsStrip: View {
  let images: [NSImage]
  let links: [URL]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Detected images")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(Array(images.prefix(6).enumerated()), id: \.offset) { _, img in
            Image(nsImage: img)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: 140, height: 92)
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
          }

          ForEach(Array(links.prefix(6)), id: \.absoluteString) { url in
            AsyncImage(url: url) { phase in
              switch phase {
              case .empty:
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
              case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
              case .failure:
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
                  .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
              @unknown default:
                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
              }
            }
            .frame(width: 140, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
          }
        }
      }
    }
  }
}

private struct DetectedLinksView: View {
  let title: String
  let links: [URL]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(links, id: \.absoluteString) { url in
          HStack(spacing: 8) {
            Text(url.absoluteString)
              .font(.system(size: 11, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Button("Open") {
              NSWorkspace.shared.open(url)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
          }
        }
      }
      .padding(10)
      .background(.black.opacity(0.12))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }
  }
}


