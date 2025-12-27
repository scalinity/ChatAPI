import Foundation

struct OpenRouterModelsResponse: Codable {
  var data: [OpenRouterModel]
}

/// Minimal model metadata for dynamic discovery.
/// - NOTE: OpenRouter returns rich metadata; we decode only what we need and keep everything optional.
struct OpenRouterModel: Codable, Identifiable, Hashable {
  struct Pricing: Codable, Hashable {
    var prompt: String?
    var completion: String?
  }

  let id: String
  var name: String?
  var description: String?
  var context_length: Int?
  var pricing: Pricing?
}



