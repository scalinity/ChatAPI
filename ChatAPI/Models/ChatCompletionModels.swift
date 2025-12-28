import Foundation

struct Reasoning: Codable, Hashable {
  /// When `nil`, the key can be omitted entirely by the request builder.
  var enabled: Bool?
  /// OpenRouter-normalized effort hint (e.g., "low", "high", "xhigh").
  var effort: String?
  /// Some models support excluding reasoning tokens from the visible output.
  var exclude: Bool?
}

struct ChatCompletionRequest: Codable, Hashable {
  var model: String
  var messages: [Message]

  var temperature: Double?
  var top_p: Double?
  var frequency_penalty: Double?
  var presence_penalty: Double?
  var max_tokens: Int?

  var stream: Bool?
  var reasoning: Reasoning?
}

// MARK: - Non-streaming response (OpenAI-style)

struct ChatCompletionResponse: Codable, Hashable {
  struct Choice: Codable, Hashable {
    var index: Int
    var message: Message
    var finish_reason: String?
  }

  var id: String?
  var model: String?
  var choices: [Choice]
}

// MARK: - Streaming response chunk (SSE)

struct ChatCompletionChunk: Codable, Hashable {
  struct Choice: Codable, Hashable {
    struct Delta: Codable, Hashable {
      var role: MessageRole?
      var content: String?
    }

    var index: Int?
    var delta: Delta?
    var finish_reason: String?
  }

  var id: String?
  var model: String?
  var choices: [Choice]?
}



