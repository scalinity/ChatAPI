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

  /// Extracts provider from model ID (e.g., "openai" from "openai/gpt-4o").
  var provider: String {
    id.components(separatedBy: "/").first ?? id
  }

  /// Model name without provider prefix (e.g., "gpt-4o" from "openai/gpt-4o").
  var shortName: String {
    let parts = id.components(separatedBy: "/")
    return parts.count > 1 ? parts.dropFirst().joined(separator: "/") : id
  }
}

// MARK: - OpenRouter Model Ordering

/// Shared comparator for sorting OpenRouter models (newest first, then by context length).
enum OpenRouterModelComparator {
  static func compareNewestFirst(_ a: OpenRouterModel, _ b: OpenRouterModel) -> Bool {
    let ca = a.created ?? 0
    let cb = b.created ?? 0
    if ca != cb { return ca > cb }
    let la = a.context_length ?? 0
    let lb = b.context_length ?? 0
    if la != lb { return la > lb }
    return a.id < b.id
  }
}

// MARK: - Model Catalog Grouping

/// Groups models by provider with popularity-based ordering.
struct ModelCatalog {
  /// Provider group containing models sorted newest-first.
  struct ProviderGroup: Identifiable {
    let id: String // provider slug
    let displayName: String
    let models: [OpenRouterModel]
  }

  /// Provider popularity rankings based on OpenRouter usage.
  /// Lower index = higher priority (appears first).
  private static let providerPopularity: [String] = [
    "openai",
    "anthropic",
    "google",
    "meta-llama",
    "mistralai",
    "x-ai",
    "deepseek",
    "perplexity",
    "cohere",
    "microsoft",
    "qwen",
    "nvidia",
    "amazon",
    "inflection",
    "nous",
    "openchat",
    "phind",
    "pygmalionai",
    "cognitivecomputations",
    "nousresearch",
  ]

  /// Human-readable provider names.
  private static let providerDisplayNames: [String: String] = [
    "openai": "OpenAI",
    "anthropic": "Anthropic",
    "google": "Google",
    "meta-llama": "Meta",
    "mistralai": "Mistral",
    "x-ai": "xAI",
    "deepseek": "DeepSeek",
    "perplexity": "Perplexity",
    "cohere": "Cohere",
    "microsoft": "Microsoft",
    "qwen": "Qwen",
    "nvidia": "NVIDIA",
    "amazon": "Amazon",
    "inflection": "Inflection",
    "nous": "Nous",
    "openchat": "OpenChat",
    "phind": "Phind",
    "pygmalionai": "Pygmalion",
    "cognitivecomputations": "Cognitive Computations",
    "nousresearch": "Nous Research",
  ]

  /// Groups models by provider, sorted by popularity then alphabetically.
  /// Within each group, models are sorted newest-first (by created timestamp).
  static func groupByProvider(_ models: [OpenRouterModel]) -> [ProviderGroup] {
    // Group models by provider
    var grouped: [String: [OpenRouterModel]] = [:]
    for model in models {
      let provider = model.provider
      grouped[provider, default: []].append(model)
    }

    // Sort models within each group: newest first (by created timestamp)
    for (provider, providerModels) in grouped {
      grouped[provider] = providerModels.sorted(by: OpenRouterModelComparator.compareNewestFirst)
    }

    // Sort providers: popularity order first, then alphabetical for unknowns
    let sortedProviders = grouped.keys.sorted { a, b in
      let aIdx = providerPopularity.firstIndex(of: a) ?? Int.max
      let bIdx = providerPopularity.firstIndex(of: b) ?? Int.max
      if aIdx != bIdx { return aIdx < bIdx }
      return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    return sortedProviders.compactMap { provider in
      guard let models = grouped[provider], !models.isEmpty else { return nil }
      let displayName = providerDisplayNames[provider] ?? provider.capitalized
      return ProviderGroup(id: provider, displayName: displayName, models: models)
    }
  }
}



