import Foundation
import Synchronization

public struct FileMetadata: Sendable, Equatable {
  public let size: Int64?
  public let mime: String?
  public init(size: Int64?, mime: String?) { self.size = size; self.mime = mime }
  public init(response: HTTPURLResponse) {
    size = response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
      ?? response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    mime = response.mimeType
  }
}

public enum FileTransferFailure: Error, LocalizedError, Sendable, Equatable {
  case notFound, connection, authentication, failed
  public var errorDescription: String? {
    switch self {
    case .notFound: "Arquivo não encontrado no Mac"
    case .connection: "Sem conexão com o servidor"
    case .authentication: "A autenticação do servidor não foi aceita"
    case .failed: "Não foi possível abrir o arquivo"
    }
  }
  public static func map(_ error: any Error) -> Self {
    if let error = error as? Self { return error }
    if let error = error as? ClientError {
      switch error {
      case .http(400), .http(403), .http(404), .locationNotFound: return .notFound
      case .http(401): return .authentication
      default: return .failed
      }
    }
    return error is URLError ? .connection : .failed
  }
}

extension OpenCodeClient {
  public func fileRequest(path: String, metadata: Bool = false) -> URLRequest {
    var result = imageFileRequest(path: path)
    result.setValue("*/*", forHTTPHeaderField: "Accept")
    result.setValue(metadata ? "bytes=0-0" : nil, forHTTPHeaderField: "Range")
    result.timeoutInterval = 45
    return result
  }
}

public struct FileTransfer: Sendable {
  private let session: URLSession
  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 45
    configuration.timeoutIntervalForResource = 60 * 30
    session = URLSession(configuration: configuration)
  }

  public func metadata(_ request: URLRequest) async throws -> FileMetadata {
    // A one-byte range also works on releases without a HEAD endpoint.
    let (bytes, raw) = try await session.bytes(for: request)
    if let empty = raw as? HTTPURLResponse, empty.statusCode == 416,
      empty.value(forHTTPHeaderField: "Content-Range") == "bytes */0" { return FileMetadata(response: empty) }
    let response = try Self.validate(raw)
    for try await _ in bytes { break }
    return FileMetadata(response: response)
  }

  public func download(_ request: URLRequest, progress: @escaping @Sendable (Int64, Int64) -> Void)
    async throws -> URL {
    let (file, response) = try await session.download(for: request, delegate: FileDownloadProgress(update: progress))
    do { _ = try Self.validate(response) }
    catch { try? FileManager.default.removeItem(at: file); throw error }
    return file
  }

  private static func validate(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else { throw FileTransferFailure.connection }
    if response.statusCode == 401 { throw FileTransferFailure.authentication }
    if [400, 403, 404].contains(response.statusCode) { throw FileTransferFailure.notFound }
    guard (200..<300).contains(response.statusCode) else { throw FileTransferFailure.failed }
    return response
  }
}

private final class FileDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
  let update: @Sendable (Int64, Int64) -> Void
  private let previous = Mutex(ContinuousClock.now)
  init(update: @escaping @Sendable (Int64, Int64) -> Void) { self.update = update }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let notify = previous.withLock { instant in
      let now = ContinuousClock.now
      guard totalBytesWritten == totalBytesExpectedToWrite || instant.duration(to: now) >= .milliseconds(100) else { return false }
      instant = now
      return true
    }
    if notify { update(totalBytesWritten, totalBytesExpectedToWrite) }
  }
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public enum FilePreviewStorage {
  public static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenCodeFilePreviews", isDirectory: true)
  public static func clean() {
    guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
    for file in files { try? FileManager.default.removeItem(at: file) }
  }
  public static func store(_ source: URL, name: String) throws -> URL {
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let destination = folder.appendingPathComponent(name)
    try FileManager.default.moveItem(at: source, to: destination)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
    return destination
  }
  public static func store(_ data: Data, name: String) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return try store(temporary, name: name)
  }
  public static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}
