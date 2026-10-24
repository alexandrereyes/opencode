import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DraftAttachment: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let mime: String
  public let size: Int
  public let remotePath: String?
  public let quoteID: String?
  public init(
    id: String = UUID().uuidString, name: String, mime: String, size: Int,
    remotePath: String? = nil,
    quoteID: String? = nil
  ) {
    self.id = id
    self.name = name
    self.mime = mime
    self.size = size
    self.remotePath = remotePath
    self.quoteID = quoteID
  }
}
extension DraftAttachment {
  /// The web's comment attachment part; delivery makes it inline image bytes or a staged path.
  public var commentPart: JSONValue {
    var part: [String: JSONValue] = [
      "type": .string(mime.hasPrefix("image/") ? "image" : "path"), "id": .string(id),
      "filename": .string(name), "mime": .string(mime),
    ]
    if !mime.hasPrefix("image/") { part["path"] = .string(remotePath ?? "") }
    return .object(part)
  }
}
public struct DeliveredAttachment: Sendable {
  public let attachment: DraftAttachment
  public let path: String
  public let inline: String?
  public init(attachment: DraftAttachment, path: String, inline: String?) {
    self.attachment = attachment
    self.path = path
    self.inline = inline
  }
}
public enum AttachmentEncoding {
  public static let inlineLimit = 20 * 1024 * 1024
  public static let draftLimit = 25 * 1024 * 1024
  public static func inline(mime: String, size: Int, input: [String]) -> Bool {
    guard size <= inlineLimit else { return false }
    if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
      return input.contains("image")
    }
    return mime == "application/pdf" && input.contains("pdf")
  }
  public static func convertToJPEG(mime: String, width: Int, height: Int) -> Bool {
    ["image/heic", "image/heif"].contains(mime)
      || (["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mime)
        && max(width, height) > 2048)
  }
  public static func prepare(_ data: Data, name: String, mime: String) throws -> (
    Data, String, String
  ) {
    guard mime.hasPrefix("image/"),
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return (data, name, mime) }
    let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
    let detectedMIME = type?.preferredMIMEType ?? mime
    guard convertToJPEG(mime: detectedMIME, width: width, height: height) else {
      return (
        data,
        (name as NSString).deletingPathExtension + "."
          + (type?.preferredFilenameExtension ?? (name as NSString).pathExtension), detectedMIME
      )
    }
    guard let image = AttachmentImage.thumbnail(data, maxPixelSize: 2048) else {
      throw AttachmentError.image
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw AttachmentError.image
    }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw AttachmentError.image }
    return (output as Data, (name as NSString).deletingPathExtension + ".jpg", "image/jpeg")
  }
}
public enum AttachmentError: Error, LocalizedError {
  case image, destination, tooLarge
  public var errorDescription: String? {
    switch self {
    case .image: "Não foi possível converter a imagem."
    case .destination: "O servidor não informou o diretório de anexos."
    case .tooLarge:
      "Os anexos do rascunho excedem 25 MiB. Remova um anexo antes de adicionar outro."
    }
  }
}
extension OpenCodeClient {
  public func deliver(
    _ attachment: DraftAttachment, bytes: Data, directory: String, input: [String]
  ) async throws -> DeliveredAttachment {
    guard let tmp = try await info().paths?.tmp else { throw AttachmentError.destination }
    let path = URL(fileURLWithPath: tmp).appendingPathComponent("uploads")
      .appendingPathComponent(attachment.id).appendingPathComponent(attachment.name).path
    var request = request(
      "/api/experimental/fs/write",
      query: [
        .init(name: "location[directory]", value: directory), .init(name: "path", value: path),
      ])
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = bytes
    _ = try await data(request)
    return DeliveredAttachment(
      attachment: attachment, path: path,
      inline: AttachmentEncoding.inline(mime: attachment.mime, size: bytes.count, input: input)
        ? "data:\(attachment.mime);base64,\(bytes.base64EncodedString())" : nil)
  }
  public func command(_ name: String, request: PromptRequest, sessionID: String) async throws {
    struct Input: Encodable {
      let name: String
      let text: String
      let files: [JSONValue]?
      let agents: [JSONValue]?
      let skills: [JSONValue]?
      let delivery: PromptDelivery
    }
    try await post(
      "/api/session/\(sessionID)/command",
      input: Input(
        name: name, text: request.text,
        files: request.files, agents: request.agents, skills: request.skills,
        delivery: request.delivery))
  }
  public func compact(_ sessionID: String, id: String) async throws {
    struct Input: Encodable {
      let id: String
      let delivery = "steer"
    }
    try await post("/api/session/\(sessionID)/compact", input: Input(id: id))
  }
}
