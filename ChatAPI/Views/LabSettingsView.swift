import SwiftUI

struct LabSettingsView: View {
  @EnvironmentObject private var chat: ChatViewModel
  @State private var modelQuery: String = ""
  @State private var apiKeyDraft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          statelessSection
          modelSection
          systemPromptSection
          parametersSection
          reasoningSection
          rawSection
        }
        .padding(16)
      }
    }
  }

  private var header: some View {
    HStack {
      Text("Inspector")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
    }
    .padding(12)
  }

  private var statelessSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Native State Protocol")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      Toggle("Context Free (Stateless)", isOn: $chat.settings.isContextFree)
        .toggleStyle(.switch)
        .help("When enabled, the model receives ONLY the current prompt. UI history remains local only.")

      VStack(alignment: .leading, spacing: 6) {
        Text("OpenRouter API Key (RAM only)")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          SecureField("sk-or-v1-…", text: $apiKeyDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              chat.setAPIKeyPersistently(apiKeyDraft)
              apiKeyDraft.removeAll(keepingCapacity: false)
              chat.refreshModels()
            }

          Button("Set") {
            chat.setAPIKeyPersistently(apiKeyDraft)
            apiKeyDraft.removeAll(keepingCapacity: false)
            chat.refreshModels()
          }
          .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button("Load") {
            chat.loadAPIKeyFromKeychain()
            chat.refreshModels()
          }
          .help("Load saved key from Keychain (may prompt for password)")
          .disabled(!chat.apiKey.isEmpty)

          Button("Forget") {
            chat.forgetAPIKey()
          }
          .disabled(chat.apiKey.isEmpty)
        }

        Text(chat.apiKey.isEmpty ? "Key not loaded - click Load or enter key" : "Key loaded")
          .font(.system(size: 11))
          .foregroundStyle(chat.apiKey.isEmpty ? Color.secondary : Color.green)
      }
    }
  }

  private var modelSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Model")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      TextField("Search models", text: $modelQuery)
        .textFieldStyle(.roundedBorder)

      Picker("Selected", selection: $chat.selectedModelID) {
        if chat.models.isEmpty {
          Text(chat.selectedModelID).tag(chat.selectedModelID)
        } else if filteredGroupedModels.isEmpty {
          // Show feedback when search has no matches
          Text("No matches").tag(chat.selectedModelID)
        } else {
          ForEach(filteredGroupedModels) { group in
            Section(header: Text(group.displayName)) {
              ForEach(group.models) { model in
                Text(model.shortName).tag(model.id)
              }
            }
          }
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)

      // Show selected model info
      if let selected = chat.selectedModel {
        Text(selected.id)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary)
      }

      Button("Refresh Model List") {
        chat.refreshModels()
      }
      .disabled(chat.isSending)
    }
  }

  private var systemPromptSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("System Prompt (Null-Hypothesis)")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      TextEditor(text: $chat.systemPromptText)
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 90)
        .overlay(
          RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .help("If empty, the system field is omitted from the JSON payload entirely.")
    }
  }

  private var parametersSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Sampling Parameters")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      LabeledSlider(label: "Temperature", value: $chat.settings.temperature, range: 0...2)
      LabeledSlider(label: "Top P", value: $chat.settings.topP, range: 0...1)
      LabeledSlider(label: "Frequency Penalty", value: $chat.settings.frequencyPenalty, range: -2...2)
      LabeledSlider(label: "Presence Penalty", value: $chat.settings.presencePenalty, range: -2...2)
    }
  }

  private var reasoningSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Reasoning / Thinking")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      Toggle("Thinking: ON", isOn: $chat.settings.reasoningEnabled)
        .toggleStyle(.switch)

      TextField("Effort (e.g., xhigh)", text: $chat.settings.reasoningEffort)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12, design: .monospaced))
    }
  }

  private var rawSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Raw JSON / SSE Transcript")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      ReadOnlyCodeBox(text: chat.rawJSONTranscript, minHeight: 160, stroke: .white.opacity(0.08))

      if !chat.rawErrorBody.isEmpty {
        Text("Raw Error Body")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
        ReadOnlyCodeBox(text: chat.rawErrorBody, minHeight: 120, stroke: .red.opacity(0.35))
      }
    }
  }

  /// Groups models by provider, filtered by search query.
  /// Always includes the currently selected model to prevent orphaned selection.
  private var filteredGroupedModels: [ModelCatalog.ProviderGroup] {
    let q = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let groups = chat.groupedModels
    let selectedID = chat.selectedModelID

    // No filter: return all groups
    guard !q.isEmpty else { return groups }

    // Filter models within each group, always keeping selected model
    return groups.compactMap { group in
      let filtered = group.models.filter { model in
        // Always include currently selected model to prevent orphaned selection
        model.id == selectedID ||
        model.id.localizedCaseInsensitiveContains(q) ||
        model.shortName.localizedCaseInsensitiveContains(q) ||
        (model.name?.localizedCaseInsensitiveContains(q) ?? false)
      }
      guard !filtered.isEmpty else { return nil }
      return ModelCatalog.ProviderGroup(
        id: group.id,
        displayName: group.displayName,
        models: filtered
      )
    }
  }
}

private struct ReadOnlyCodeBox: View {
  let text: String
  let minHeight: CGFloat
  let stroke: Color

  var body: some View {
    ScrollView {
      Text(text.isEmpty ? "—" : text)
        .textSelection(.enabled)
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
    .frame(minHeight: minHeight)
    .background(.black.opacity(0.15))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct LabeledSlider: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label)
        Spacer()
        Text(String(format: "%.2f", value))
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: range)
    }
    .font(.system(size: 12))
  }
}


