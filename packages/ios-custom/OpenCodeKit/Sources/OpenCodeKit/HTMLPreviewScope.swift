import Foundation

/// The files an HTML preview may load in its default "local files" mode: the page's folder and its subfolders,
/// plus the Session directory when the page lives inside it. Pages are served from
/// `opencode-preview://<token>/<absolute path>`, so relative URLs resolve like on disk; the random token makes
/// every opened page its own origin.
public struct HTMLPreviewScope: Sendable, Equatable {
  public static let scheme = "opencode-preview"
  /// Each resource is read whole into memory; larger ones fail like a missing file.
  public static let resourceLimit: Int64 = 25 * 1024 * 1024

  public let file: String
  public let roots: [String]
  public let token: String

  public init(file: String, sessionDirectory: String, token: String = UUID().uuidString.lowercased()) {
    let file = ProjectExplorer.canonical(file)
    let folder = ProjectExplorer.canonical(URL(fileURLWithPath: file).deletingLastPathComponent().path)
    let session = ProjectExplorer.canonical(sessionDirectory)
    self.file = file
    self.token = token
    // The innermost root first: reads use it as their Location, so the server also refuses symlinks leaving it.
    roots = Self.contains(session, file) && session != folder ? [folder, session] : [folder]
  }

  public var pageURL: URL { url(file) }

  public func url(_ path: String) -> URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = token
    components.path = path
    return components.url!
  }

  /// The server read for a URL the page requested: the root to use as Location and the path relative to it.
  /// Anything else (another page's token, `..` leaving every root, an absolute path outside them, a folder) is nil.
  public func resolve(_ url: URL) -> (root: String, relative: String)? {
    guard url.scheme == Self.scheme, url.host == token, url.user == nil, url.port == nil else { return nil }
    let raw = url.path(percentEncoded: false)
    guard !raw.isEmpty, !raw.hasSuffix("/"), !raw.contains("\u{0}") else { return nil }
    let path = ProjectExplorer.canonical(raw)
    guard let root = roots.first(where: { Self.contains($0, path) }) else { return nil }
    return (root, String(path.dropFirst(root == "/" ? 1 : root.count + 1)))
  }

  /// Same-origin pages of this scope may follow their links inside the preview.
  public func isPage(_ url: URL) -> Bool {
    guard let path = resolve(url).map({ $0.root + "/" + $0.relative }) else { return false }
    return ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  static func contains(_ root: String, _ path: String) -> Bool {
    root == "/" ? path != "/" : path.hasPrefix(root + "/")
  }

  public static func mime(_ path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "html", "htm": "text/html"
    case "css": "text/css"
    case "js", "mjs", "cjs": "text/javascript"
    case "json", "map": "application/json"
    case "wasm": "application/wasm"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "avif": "image/avif"
    case "ico": "image/x-icon"
    case "bmp": "image/bmp"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    case "ttf": "font/ttf"
    case "otf": "font/otf"
    case "txt", "log", "md": "text/plain"
    case "xml": "application/xml"
    case "csv": "text/csv"
    case "mp4", "m4v": "video/mp4"
    case "webm": "video/webm"
    case "mp3": "audio/mpeg"
    case "wav": "audio/wav"
    default: "application/octet-stream"
    }
  }

  /// A second wall behind the content rule list: the page may only reach its own origin and inline data.
  public static let contentSecurityPolicy = [
    "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:",
    "connect-src 'self' data: blob:",
    "frame-src 'self' blob:",
    "form-action 'none'",
    "base-uri 'self'",
  ].joined(separator: "; ")
}

extension OpenCodeClient {
  /// One preview resource, read with the scope root as Location: the server refuses `..` and symlinks leaving it.
  public func previewResource(_ relative: String, root: String) async throws -> Data {
    var request = request("/api/fs/read/" + relative, query: [URLQueryItem(name: "location[directory]", value: root)])
    // One byte past the limit is enough to know the file is too large.
    request.setValue("bytes=0-\(HTMLPreviewScope.resourceLimit)", forHTTPHeaderField: "Range")
    let data = try await data(request)
    guard Int64(data.count) <= HTMLPreviewScope.resourceLimit else { throw FileTransferFailure.failed }
    return data
  }
}
