import Foundation

enum MessageRole: String, Codable, Hashable {
  case system
  case user
  case assistant
  case tool
}

// MARK: - Multimodal Content Types (OpenRouter/OpenAI format)

/// Content part for multimodal messages.
/// Supports text and image_url types per OpenRouter API.
enum MessageContentPart: Codable, Hashable {
  case text(String)
  case imageURL(url: String, detail: String?)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case image_url
  }

  struct ImageURLContent: Codable, Hashable {
    let url: String
    var detail: String?
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "text":
      let text = try container.decode(String.self, forKey: .text)
      self = .text(text)
    case "image_url":
      let imageContent = try container.decode(ImageURLContent.self, forKey: .image_url)
      self = .imageURL(url: imageContent.url, detail: imageContent.detail)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unknown content type: \(type)"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .imageURL(let url, let detail):
      try container.encode("image_url", forKey: .type)
      try container.encode(ImageURLContent(url: url, detail: detail), forKey: .image_url)
    }
  }
}

/// UI + Networking message model with multimodal support.
/// - PRIVACY: The `id` and `attachments` are local-only and never encoded into the API payload.
struct Message: Identifiable, Hashable {
  let id: UUID
  var role: MessageRole
  var content: String

  /// Local-only: attachments associated with this message (for UI display).
  var attachments: [Attachment]

  /// Whether this message has multimodal content (images).
  var isMultimodal: Bool {
    attachments.contains { $0.isImage }
  }

  init(id: UUID = UUID(), role: MessageRole, content: String, attachments: [Attachment] = []) {
    self.id = id
    self.role = role
    self.content = content
    self.attachments = attachments
  }

  // MARK: - Equatable (required since we have custom Codable init)

  static func == (lhs: Message, rhs: Message) -> Bool {
    lhs.id == rhs.id &&
    lhs.role == rhs.role &&
    lhs.content == rhs.content &&
    lhs.attachments == rhs.attachments
  }

  // MARK: - Hashable

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(role)
    hasher.combine(content)
    hasher.combine(attachments)
  }
}

// MARK: - API Encoding

/// Error type for message encoding failures.
enum MessageEncodingError: Error, LocalizedError {
  case attachmentEncodingFailed(filename: String, reason: String)

  var errorDescription: String? {
    switch self {
    case .attachmentEncodingFailed(let filename, let reason):
      return "Failed to encode attachment '\(filename)': \(reason)"
    }
  }
}

extension Message {
  /// Encodes the message for the OpenRouter API.
  /// - Returns: A dictionary suitable for JSON encoding.
  /// - Throws: `MessageEncodingError` if any attachment fails to encode.
  /// - Note: For multimodal messages, content becomes an array of content parts.
  func toAPIPayload() throws -> [String: Any] {
    var payload: [String: Any] = ["role": role.rawValue]

    let imageAttachments = attachments.filter { $0.isImage }

    if imageAttachments.isEmpty {
      // Simple text-only message
      payload["content"] = content
    } else {
      // Multimodal message with images
      var contentParts: [[String: Any]] = []

      // Add text content first (if not empty)
      let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedContent.isEmpty {
        contentParts.append([
          "type": "text",
          "text": trimmedContent,
        ])
      }

      // Add image attachments as base64 data URLs
      for attachment in imageAttachments {
        // SECURITY: Check for encoding errors before attempting to encode
        if let error = attachment.encodingError {
          throw MessageEncodingError.attachmentEncodingFailed(
            filename: attachment.filename,
            reason: error
          )
        }
        guard let dataURL = attachment.base64DataURL else {
          throw MessageEncodingError.attachmentEncodingFailed(
            filename: attachment.filename,
            reason: "Failed to encode image as base64"
          )
        }
        contentParts.append([
          "type": "image_url",
          "image_url": [
            "url": dataURL,
            "detail": "auto",
          ],
        ])
      }

      payload["content"] = contentParts
    }

    return payload
  }

  /// Non-throwing version for backwards compatibility.
  /// Silently drops attachments that fail to encode.
  func toAPIPayloadLenient() -> [String: Any] {
    var payload: [String: Any] = ["role": role.rawValue]

    let imageAttachments = attachments.filter { $0.isImage && $0.canEncode }

    if imageAttachments.isEmpty {
      payload["content"] = content
    } else {
      var contentParts: [[String: Any]] = []

      let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedContent.isEmpty {
        contentParts.append([
          "type": "text",
          "text": trimmedContent,
        ])
      }

      for attachment in imageAttachments {
        if let dataURL = attachment.base64DataURL {
          contentParts.append([
            "type": "image_url",
            "image_url": [
              "url": dataURL,
              "detail": "auto",
            ],
          ])
        }
      }

      payload["content"] = contentParts
    }

    return payload
  }
}

// MARK: - Codable Conformance (for simple text messages)

extension Message: Codable {
  enum CodingKeys: String, CodingKey {
    case role
    case content
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = UUID()
    self.role = try container.decode(MessageRole.self, forKey: .role)
    self.attachments = []

    // Handle both string content and array content (multimodal)
    if let textContent = try? container.decode(String.self, forKey: .content) {
      self.content = textContent
    } else if let contentParts = try? container.decode([MessageContentPart].self, forKey: .content) {
      // Extract text from multimodal content
      self.content = contentParts.compactMap { part in
        if case .text(let text) = part { return text }
        return nil
      }.joined(separator: "\n")
    } else {
      self.content = ""
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encode(content, forKey: .content)
  }
}



