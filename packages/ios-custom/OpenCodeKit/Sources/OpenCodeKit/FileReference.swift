import Foundation

public enum FileReference {
  fileprivate static let filenames: Set<String> = [
    "CHANGELOG", "CODEOWNERS", "Containerfile", "Dockerfile", "Gemfile", "Justfile", "LICENSE",
    "Makefile", "Procfile", "README", "Rakefile", "Vagrantfile",
  ]

  public static func inlineURL(_ source: String) -> URL? {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"[),.;!?]+$"#, with: "", options: .regularExpression)
    guard value.range(of: #"^https?://[^\s<>()`\"']+$"#, options: .regularExpression) != nil else { return nil }
    return URL(string: value)
  }

  public static func inline(_ text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace),
      text.range(of: #"[{}<>\"'`;=|&*,]"#, options: .regularExpression) == nil,
      text.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) == nil,
      text.range(of: #"^[/\\]{2}"#, options: .regularExpression) == nil, let path = local(text)
    else { return nil }
    return filenames.contains(path) || path.range(of: #"[./\\]"#, options: .regularExpression) != nil
      && path.range(of: "[a-z]", options: [.regularExpression, .caseInsensitive]) != nil ? path : nil
  }

  public static func local(_ source: String) -> String? {
    guard !source.isEmpty, !source.contains("…"),
      source.range(of: #"(?:^|[/\\])\.\.\.(?:[/\\]|$)"#, options: .regularExpression) == nil,
      !source.hasPrefix("#"), source.range(of: #"^[/\\]{2}"#, options: .regularExpression) == nil else { return nil }
    if source.hasPrefix("file:"), let url = URL(string: source), url.isFileURL,
      url.host == nil || url.host == "" || url.host == "localhost" { return url.path }
    let path = source.replacingOccurrences(of: #"#L\d+(?:C\d+)?(?:-L?\d+(?:C\d+)?)?$"#, with: "", options: [.regularExpression, .caseInsensitive])
      .replacingOccurrences(of: #":\d+(?::\d+)?(?:-\d+(?::\d+)?)?:?$"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\", with: "/")
    guard URLComponents(string: path)?.scheme == nil
      || path.range(of: #"^[a-z]:/"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
    return path.isEmpty ? nil : path
  }

  /// A server folder confirmed by `fileLinkTarget`; it opens in the file explorer.
  public static func folderLink(_ path: String) -> URL { link(path, host: "folder") }

  public static func isFolder(_ url: URL) -> Bool { url.scheme == "opencode-file" && url.host == "folder" }

  public static func link(_ path: String) -> URL { link(path, host: "open") }

  private static func link(_ path: String, host: String) -> URL {
    var url = URLComponents()
    url.scheme = "opencode-file"
    url.host = host
    url.queryItems = [URLQueryItem(name: "path", value: path)]
    return url.url!
  }

  public static func path(_ url: URL) -> String? {
    guard url.scheme == "opencode-file" else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
  }
}

public enum FileViewerKind: Sendable, Equatable {
  case image, audiovisual, preview, unknown
  public init(path: String, mime: String? = nil) {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    // ImageIO cannot draw SVG, although its MIME type is image/*.
    if ["ts", "tsx", "svg"].contains(ext) || mime == "image/svg+xml" { self = .preview; return }
    if mime?.hasPrefix("image/") == true || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tiff", "ico"].contains(ext) {
      self = .image; return
    }
    if mime?.hasPrefix("video/") == true || mime?.hasPrefix("audio/") == true
      || ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aac", "caf", "flac"].contains(ext) {
      self = .audiovisual; return
    }
    self = FileReference.filenames.contains(URL(fileURLWithPath: path).lastPathComponent)
      || [".gitignore", ".env", ".npmrc", ".editorconfig"].contains(URL(fileURLWithPath: path).lastPathComponent)
      || ["pdf", "txt", "md", "markdown", "json", "csv", "tsv", "log", "swift", "ts", "tsx", "js", "jsx", "py", "rb", "sh", "yml", "yaml", "toml", "xml", "html", "css", "c", "h", "cpp", "rs", "go", "sql", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "svg"].contains(ext)
      || mime?.hasPrefix("text/") == true ? .preview : .unknown
  }
  public static let confirmationBytes: Int64 = 50 * 1024 * 1024
  public static func requiresConfirmation(_ size: Int64?) -> Bool { (size ?? 0) > confirmationBytes }
}
