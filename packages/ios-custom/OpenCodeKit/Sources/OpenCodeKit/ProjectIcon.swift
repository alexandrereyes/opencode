import CryptoKit
import Foundation
import ImageIO

/// A project's own icon, picked like the web sidebar: `icon.override`, else the discovered `icon.url` unless a color
/// was chosen. Only inline data URLs qualify (SVG, or a raster ImageIO decodes) up to `maximumBytes`; nothing remote
/// is ever fetched.
public struct ProjectIcon: Sendable, Hashable {
  public static let maximumBytes = 256 * 1024
  public let svg: Bool
  public let data: Data
  /// Content hash, so a replaced icon never reuses an earlier render.
  public let key: String

  public init?(_ project: Project?) {
    guard let icon = project?.icon, let source = icon.override ?? (icon.color == nil ? icon.url : nil) else {
      return nil
    }
    self.init(dataURL: source)
  }

  public init?(dataURL: String) {
    guard dataURL.utf8.count <= Self.maximumBytes * 4 / 3 + 1024, dataURL.lowercased().hasPrefix("data:image/"),
      let comma = dataURL.firstIndex(of: ",")
    else { return nil }
    let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma].lowercased().split(separator: ";")
    let payload = String(dataURL[dataURL.index(after: comma)...])
    let decoded =
      header.contains("base64")
      ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
      : payload.removingPercentEncoding.map { Data($0.utf8) }
    guard let decoded, !decoded.isEmpty, decoded.count <= Self.maximumBytes else { return nil }
    svg = header.first == "image/svg+xml"
    data = decoded
    key = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
  }
}

/// Project icons at chip size: memory first, then SVG renders saved on disk by `ProjectIcon.key`, so each icon
/// revision is rasterized once, not on every render, scroll or launch.
public actor ProjectIconCache {
  public static let shared = ProjectIconCache()
  public static let pixels = 96
  private let disk: URL
  // NSCache is thread-safe; reading it synchronously lets a view draw a decoded icon on its first frame.
  private nonisolated(unsafe) let memory = NSCache<NSString, CGImage>()
  private var pending: [String: Task<CGImage?, Never>] = [:]
  private var failed: Set<String> = []

  public init(directory: URL? = nil) {
    disk = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ProjectIcons-v1", isDirectory: true)
  }

  /// Already decoded in this process.
  public nonisolated func cached(_ icon: ProjectIcon) -> CGImage? { memory.object(forKey: icon.key as NSString) }

  /// `render` turns SVG data into PNG data of `pixels` × `pixels`; it runs at most once per icon revision.
  public func image(_ icon: ProjectIcon, render: @escaping @Sendable (Data, Int) async -> Data?) async -> CGImage? {
    if let image = cached(icon) { return image }
    if failed.contains(icon.key) { return nil }
    if let task = pending[icon.key] { return await task.value }
    let file = disk.appendingPathComponent(icon.key + ".png")
    let directory = disk
    let task = Task<CGImage?, Never> {
      if !icon.svg { return AttachmentImage.thumbnail(icon.data, maxPixelSize: Self.pixels) }
      if let saved = try? Data(contentsOf: file), let image = AttachmentImage.thumbnail(saved, maxPixelSize: Self.pixels) {
        return image
      }
      guard let png = await render(icon.data, Self.pixels),
        let image = AttachmentImage.thumbnail(png, maxPixelSize: Self.pixels)
      else { return nil }
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? png.write(to: file, options: .atomic)
      return image
    }
    pending[icon.key] = task
    defer { pending[icon.key] = nil }
    guard let image = await task.value else {
      failed.insert(icon.key)
      return nil
    }
    memory.setObject(image, forKey: icon.key as NSString)
    return image
  }
}
