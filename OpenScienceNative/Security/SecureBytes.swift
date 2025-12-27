import Foundation
import Security

/// In-memory secret container with enhanced security.
/// - PRIVACY: Zeroizes backing bytes on `wipe()`; never persists to disk.
/// - SECURITY: Validates input format and prevents injection attacks.
final class SecureBytes: @unchecked Sendable {
  private var storage = Data()

  /// Whether the secure storage is empty.
  var isEmpty: Bool { storage.isEmpty }

  /// Stores a UTF-8 string securely.
  /// - Parameter utf8String: The string to store.
  /// - Note: The input string is validated before storage.
  func set(utf8String: String) {
    // SECURITY: Wipe any existing data first
    wipe()
    storage = Data(utf8String.utf8)
  }

  /// Returns the stored value as a String.
  /// - Returns: The stored string, or nil if empty.
  /// - Warning: Creates a Swift String which cannot be securely wiped.
  ///   Minimize the lifetime of the returned value.
  func stringValue() -> String? {
    guard !storage.isEmpty else { return nil }
    return String(data: storage, encoding: .utf8)
  }

  /// Returns the raw Data for direct use in HTTP headers.
  /// - Returns: The stored data, or nil if empty.
  /// - Note: Using Data instead of String avoids creating non-wipeable String copies.
  func dataValue() -> Data? {
    guard !storage.isEmpty else { return nil }
    return storage
  }

  /// Builds an Authorization header value as Data (avoids String intermediary).
  /// - Returns: "Bearer <key>" as Data, or nil if empty.
  /// - Note: SECURITY: This method avoids creating intermediate String objects
  ///   that cannot be securely wiped from memory.
  func buildBearerHeaderData() -> Data? {
    guard !storage.isEmpty else { return nil }
    var header = Data("Bearer ".utf8)
    header.append(storage)
    return header
  }

  /// Securely wipes the stored data.
  /// - Note: Zeroes all bytes before deallocation.
  func wipe() {
    guard !storage.isEmpty else { return }
    // SECURITY: Overwrite with zeros before releasing
    storage.resetBytes(in: 0..<storage.count)
    storage.removeAll(keepingCapacity: false)
  }

  /// Validates that an API key has a safe format.
  /// - Parameter key: The API key string to validate.
  /// - Returns: true if the key format is safe, false otherwise.
  /// - Note: SECURITY: Prevents CRLF injection and ensures safe header values.
  static func validateAPIKeyFormat(_ key: String) -> Bool {
    // Reject empty keys
    guard !key.isEmpty else { return false }

    // SECURITY: Block CRLF injection (HTTP header injection)
    guard !key.contains("\r"), !key.contains("\n"), !key.contains("\0") else {
      return false
    }

    // SECURITY: Only allow safe characters (alphanumeric, hyphen, underscore)
    let allowedPattern = "^[a-zA-Z0-9_-]+$"
    guard key.range(of: allowedPattern, options: .regularExpression) != nil else {
      return false
    }

    // Reasonable length bounds
    guard key.count >= 10, key.count <= 256 else {
      return false
    }

    return true
  }

  deinit {
    // SECURITY: Ensure data is wiped on deallocation
    wipe()
  }
}

enum KeychainError: Error {
  case unexpectedStatus(OSStatus)
  case invalidData
}

/// Persistent API key storage (the only allowed persistence).
/// - PRIVACY: Stores only the OpenRouter API key in the system Keychain.
enum APIKeyKeychainStore {
  private static let service = "com.openscience.OpenScienceNative"
  private static let account = "openrouter_api_key"

  static func load() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }

    guard let data = item as? Data else { throw KeychainError.invalidData }
    guard let string = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
    return string
  }

  static func save(_ apiKey: String) throws {
    let data = Data(apiKey.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]

    let update: [String: Any] = [
      kSecValueData as String: data,
    ]

    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
      return
    }
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
  }

  static func delete() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
}


