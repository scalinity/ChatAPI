import Foundation

struct OpenRouterModelsResponse: Codable {
  var data: [OpenRouterModel]
}

/// OpenRouter model metadata for dynamic discovery + capability-driven UI.
/// - NOTE: OpenRouter returns rich metadata; we decode what we need and keep everything optional.
struct OpenRouterModel: Codable, Identifiable, Hashable {
  struct Pricing: Codable, Hashable {
    var prompt: String?
    var completion: String?
    var request: String?
    var image: String?
    var video: String?
  }

  struct Architecture: Codable, Hashable {
    /// Official OpenRouter capability metadata.
    /// Common values: ["text", "image", "audio", "video", "file"]
    var input_modalities: [String]?
    var output_modalities: [String]?

    var tokenizer: String?
    var instruct_type: String?

    /// Some models expose a single modality string (kept for completeness).
    var modality: String?
  }

  let id: String
  var canonical_slug: String?
  var created: Int?
  var name: String?
  var description: String?
  var context_length: Int?
  var pricing: Pricing?
  var architecture: Architecture?

  /// OpenRouter-supported request parameters for this model (e.g., "tools", "reasoning", "temperature").
  var supported_parameters: [String]?

  // MARK: - Capability helpers (derived from official metadata)

  struct Capabilities: Hashable {
    var inputModalities: Set<String>
    var outputModalities: Set<String>
    var supportedParameters: Set<String>

    var supportsTools: Bool { supportedParameters.contains("tools") }
    var supportsReasoning: Bool { supportedParameters.contains("reasoning") }

    var supportsImageInput: Bool { inputModalities.contains("image") }
    var supportsFileInput: Bool { inputModalities.contains("file") }

    var supportsImageOutput: Bool { outputModalities.contains("image") }
    var supportsVideoOutput: Bool { outputModalities.contains("video") }
    var supportsAudioOutput: Bool { outputModalities.contains("audio") }
  }

  var capabilities: Capabilities {
    let inMods = Set((architecture?.input_modalities ?? []).map { $0.lowercased() })
    let outMods = Set((architecture?.output_modalities ?? []).map { $0.lowercased() })
    let params = Set((supported_parameters ?? []).map { $0.lowercased() })
    return Capabilities(inputModalities: inMods, outputModalities: outMods, supportedParameters: params)
  }
}



