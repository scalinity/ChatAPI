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
      
      // Content can be a string or multimodal array - we handle both in custom decoding
      var content: String?
      
      // Reasoning/thinking fields - providers use different names:
      // - OpenAI o1/o3: "reasoning_content"
      // - Some providers: "reasoning"
      // - Some: "thinking" or "thought"
      var reasoning_content: String?
      var reasoning: String?
      var thinking: String?
      
      /// Unified accessor for reasoning content from any provider format.
      var effectiveReasoning: String? {
        reasoning_content ?? reasoning ?? thinking
      }
      
      // Custom decoding to handle content as either String or [ContentPart]
      enum CodingKeys: String, CodingKey {
        case role, content, reasoning_content, reasoning, thinking
      }
      
      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(MessageRole.self, forKey: .role)
        reasoning_content = try container.decodeIfPresent(String.self, forKey: .reasoning_content)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        
        // Try to decode content as String first
        if let stringContent = try? container.decodeIfPresent(String.self, forKey: .content) {
          content = stringContent
        } else if let arrayContent = try? container.decodeIfPresent([DeltaContentPart].self, forKey: .content) {
          // Multimodal content - extract text and image data URLs
          var parts: [String] = []
          for part in arrayContent {
            if let text = part.text {
              parts.append(text)
            }
            if let imageURL = part.image_url?.url {
              parts.append(imageURL)
            }
            // Handle inline base64 image data
            if part.type == "image" || part.type == "image_url" {
              if let b64 = part.image_url?.url, b64.hasPrefix("data:image") {
                parts.append(b64)
              }
            }
          }
          content = parts.isEmpty ? nil : parts.joined(separator: "\n")
        } else {
          content = nil
        }
      }
      
      init(role: MessageRole? = nil, content: String? = nil, reasoning_content: String? = nil, reasoning: String? = nil, thinking: String? = nil) {
        self.role = role
        self.content = content
        self.reasoning_content = reasoning_content
        self.reasoning = reasoning
        self.thinking = thinking
      }
    }

    var index: Int?
    var delta: Delta?
    var finish_reason: String?
  }

  var id: String?
  var model: String?
  var choices: [Choice]?
}

/// Content part for multimodal streaming responses
private struct DeltaContentPart: Codable {
  var type: String?
  var text: String?
  var image_url: ImageURLPart?
  
  struct ImageURLPart: Codable {
    var url: String?
  }
}



