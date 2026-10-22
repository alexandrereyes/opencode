import CryptoKit
import Foundation
import ImageIO

public actor FeedImageLoader {
  public static let shared = FeedImageLoader()
  public static let maximumBytes = 32 * 1024 * 1024
  private let disk: URL
  private let memoryLimit: Int
  private let diskLimit: Int
  private var images: [String: CGImage] = [:]
  private var order: [String] = []
  private var pending: [String: Task<CGImage, any Error>] = [:]
  private var homes: [String: String] = [:]

  public init(directory: URL? = nil, memoryLimit: Int = 32 * 1024 * 1024,
    diskLimit: Int = 128 * 1024 * 1024) {
    disk = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("FeedImages-v1", isDirectory: true)
    self.memoryLimit = memoryLimit
    self.diskLimit = diskLimit
  }

  public func load(_ source: String, client: OpenCodeClient, directory: String, maxPixelSize: Int)
    async throws -> CGImage {
    let key = Self.cacheKey(source, configuration: client.configuration, directory: directory)
    let thumbnailKey = "\(key)-\(maxPixelSize)"
    if let image = images[thumbnailKey] { touch(thumbnailKey); return image }
    if let task = pending[thumbnailKey] { return try await task.value }
    let task = Task {
      let data = try await self.bytes(source, key: key, client: client, directory: directory)
      guard let image = AttachmentImage.thumbnail(data, maxPixelSize: maxPixelSize) else {
        throw FeedImageFailure.invalidImage
      }
      return image
    }
    pending[thumbnailKey] = task
    defer { pending[thumbnailKey] = nil }
    let image = try await task.value
    images[thumbnailKey] = image
    touch(thumbnailKey)
    while images.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > memoryLimit,
      let oldest = order.first {
      images.removeValue(forKey: oldest)
      order.removeFirst()
    }
    return image
  }

  public static func cacheKey(_ source: String, configuration: ServerConfiguration, directory: String) -> String {
    SHA256.hash(data: Data([configuration.url.absoluteString, configuration.password ?? "", directory, source]
      .joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func touch(_ key: String) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func bytes(_ source: String, key: String, client: OpenCodeClient, directory: String)
    async throws -> Data {
    let file = disk.appendingPathComponent(key)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let date = attributes[.modificationDate] as? Date, Date.now.timeIntervalSince(date) < 86400,
      let data = try? Data(contentsOf: file), data.count <= Self.maximumBytes {
      return data
    }
    let reference = FeedImageReference(source)
    let data: Data
    switch reference {
    case .data(let value):
      guard value.utf8.count <= Self.maximumBytes * 4 / 3 + 1024 else { throw FeedImageFailure.tooLarge }
      guard let comma = value.firstIndex(of: ","), value[..<comma].contains(";base64"),
        value[..<comma].hasPrefix("data:image/"),
        let decoded = Data(base64Encoded: String(value[value.index(after: comma)...]))
      else { throw FeedImageFailure.invalidImage }
      data = decoded
    case .local(let path):
      let server = client.configuration.url.absoluteString
      if path.hasPrefix("~"), homes[server] == nil { homes[server] = try await client.serverHome() }
      data = try await client.imageFile(path: reference.path(directory: directory, home: homes[server]))
    case .remote(let url):
      data = try await client.imageRemote(url)
    case .unsupported: throw FeedImageFailure.unsupported
    }
    guard data.count <= Self.maximumBytes else { throw FeedImageFailure.tooLarge }
    guard AttachmentImage.thumbnail(data, maxPixelSize: 1) != nil else {
      throw FeedImageFailure.invalidImage
    }
    try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
    try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    trimDisk()
    return data
  }

  private func trimDisk() {
    let files = ((try? FileManager.default.contentsOfDirectory(at: disk,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []).compactMap { url in
        (try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])).map { (url, $0) }
      }.sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
    var size = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
    for file in files where size > diskLimit {
      try? FileManager.default.removeItem(at: file.0)
      size -= file.1.fileSize ?? 0
    }
  }
}
