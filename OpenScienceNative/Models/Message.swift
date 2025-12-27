import Foundation

enum MessageRole: String, Codable, Hashable {
  case system
  case user
  case assistant
  case tool
}

/// UI + Networking message model.
/// - PRIVACY: The `id` is local-only and is never encoded into the API payload.
struct Message: Codable, Identifiable, Hashable {
  let id: UUID
  var role: MessageRole
  var content: String

  init(id: UUID = UUID(), role: MessageRole, content: String) {
    self.id = id
    self.role = role
    self.content = content
  }

  enum CodingKeys: String, CodingKey {
    case role
    case content
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = UUID()
    self.role = try container.decode(MessageRole.self, forKey: .role)
    self.content = try container.decode(String.self, forKey: .content)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encode(content, forKey: .content)
  }
}


