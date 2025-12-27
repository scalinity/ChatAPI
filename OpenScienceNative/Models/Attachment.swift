import Foundation
import UniformTypeIdentifiers

/// Represents a file attachment for multimodal messages.
/// - PRIVACY: Attachment data is stored in RAM only; never persisted to disk.
struct Attachment: Identifiable, Hashable {
  let id: UUID
  let filename: String
  let mimeType: String
  let data: Data
  let isImage: Bool

  /// File size in bytes.
  var size: Int { data.count }

  /// Human-readable file size.
  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }

  init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
    self.id = id
    self.filename = filename
    self.mimeType = mimeType
    self.data = data
    self.isImage = Self.isImageMimeType(mimeType)
  }

  /// Creates an attachment from a file URL.
  /// - Parameter url: The file URL to read from.
  /// - Returns: An attachment, or nil if the file couldn't be read.
  static func fromURL(_ url: URL) -> Attachment? {
    // Sandbox-friendly: drag & drop/open panel can provide security-scoped URLs.
    guard url.isFileURL else { return nil }
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    guard let data = try? Data(contentsOf: url) else { return nil }

    let filename = url.lastPathComponent
    let mimeType = Self.mimeType(for: url)

    return Attachment(filename: filename, mimeType: mimeType, data: data)
  }

  /// Determines the MIME type for a file URL.
  private static func mimeType(for url: URL) -> String {
    if let utType = UTType(filenameExtension: url.pathExtension) {
      return utType.preferredMIMEType ?? "application/octet-stream"
    }
    return "application/octet-stream"
  }

  /// Checks if a MIME type represents an image.
  private static func isImageMimeType(_ mimeType: String) -> Bool {
    let imageMimeTypes = [
      "image/png",
      "image/jpeg",
      "image/jpg",
      "image/gif",
      "image/webp",
      "image/svg+xml",
      "image/bmp",
      "image/tiff",
    ]
    return imageMimeTypes.contains(mimeType.lowercased())
  }

  /// Returns the base64-encoded data URL for images (OpenRouter format).
  /// Format: "data:image/png;base64,..."
  var base64DataURL: String? {
    guard isImage else { return nil }
    let base64 = data.base64EncodedString()
    return "data:\(mimeType);base64,\(base64)"
  }
}

// MARK: - Supported File Types

extension Attachment {
  /// Image file extensions supported for multimodal.
  static let supportedImageExtensions = ["png", "jpg", "jpeg", "gif", "webp"]

  /// All file extensions (for general file upload).
  static let supportedFileExtensions: [String] = [] // Empty = all types

  /// UTTypes for image file picker.
  static var imageUTTypes: [UTType] {
    var types: [UTType] = [.png, .jpeg, .gif]
    if let webp = UTType(filenameExtension: "webp") {
      types.append(webp)
    }
    return types
  }

  /// UTTypes for general file picker.
  static var allFileUTTypes: [UTType] {
    [.item] // All file types
  }
}
