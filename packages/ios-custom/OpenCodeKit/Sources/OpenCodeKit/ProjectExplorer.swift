import Foundation

/// The web's project explorer (`app-custom/src/workspaces/selection/explorer-query.ts`) for POSIX servers.
/// Its query doubles as location and filter: text up to the last `/` is the browsed directory and the
/// trailing segment filters its children, e.g. `~/Dev/op`.
public enum ProjectExplorer {
  public struct Query: Equatable, Sendable {
    public let directory: String
    public let filter: String
    public let browsed: String
    public let target: String
  }

  public struct Entry: Equatable, Sendable {
    public let name: String
    public let absolute: String
    public init(name: String, absolute: String) {
      self.name = name
      self.absolute = absolute
    }
  }

  public struct Row: Equatable, Sendable, Identifiable {
    public let name: String
    public let absolute: String
    public let added: Bool
    public let blocked: Bool
    public var id: String { absolute }
  }

  public enum Submission: Equatable, Sendable {
    case existing(String)
    case create(String)
    case added(String)
  }

  /// The web starts at `~/`; the iOS explorer starts in the server home's `Dev` folder.
  public static func start(home: String, fallback: String) -> String {
    home.isEmpty ? display(fallback, home: home) : "~/Dev/"
  }

  public static func query(_ text: String, home: String) -> Query {
    let value = normalize(text)
    let slash = value.lastIndex(of: "/")
    let directory = slash.map { String(value[...$0]) } ?? ""
    return Query(
      directory: directory,
      filter: slash.map { String(value[value.index(after: $0)...]) } ?? value,
      browsed: absolute(directory, home: home),
      target: absolute(value, home: home))
  }

  public static func absolute(_ display: String, home: String) -> String {
    let value = normalize(display.trimmingCharacters(in: .whitespaces))
    let tilde = value == "~" || value.hasPrefix("~/")
    if tilde && home.isEmpty { return "" }
    let expanded = tilde ? trim(home) + value.dropFirst() : value
    guard expanded.hasPrefix("/") else { return "" }
    return canonical(expanded)
  }

  /// Explorer paths keep a trailing slash because the query is split on it.
  public static func display(_ absolute: String, home: String) -> String {
    let value = trim(absolute)
    let root = home.isEmpty ? "" : trim(home)
    let shown =
      root.isEmpty
      ? value
      : value == root ? "~" : value.hasPrefix(root + "/") ? "~" + value.dropFirst(root.count) : value
    return shown.hasSuffix("/") ? shown : shown + "/"
  }

  public static func parent(_ text: String, home: String) -> String? {
    let current = query(text, home: home)
    guard !current.browsed.isEmpty, current.filter.isEmpty else { return nil }
    let browsed = trim(current.browsed)
    guard browsed != "/" else { return nil }
    let index = browsed.lastIndex(of: "/")!
    let parent = index == browsed.startIndex ? "/" : String(browsed[..<index])
    return display(parent, home: home)
  }

  /// The home directory and filesystem root are never projects; blocking them avoids adding them by accident.
  public static func blocked(_ path: String, home: String) -> Bool {
    let value = trim(path)
    return value == "/" || (!home.isEmpty && value == trim(home))
  }

  public static func rows(
    entries: [Entry], filter: String, hidden: Bool, added: Set<String>, home: String
  ) -> [Row] {
    let prefix = filter.lowercased()
    let showHidden = hidden || filter.hasPrefix(".")
    return
      entries
      .filter { $0.name.lowercased().hasPrefix(prefix) && (showHidden || !$0.name.hasPrefix(".")) }
      .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
      .map {
        Row(
          name: $0.name, absolute: trim($0.absolute), added: added.contains(trim($0.absolute)),
          blocked: blocked($0.absolute, home: home))
      }
  }

  public static func submission(
    query text: String, home: String, added: Set<String>, readable: Bool, rows: [Row]
  ) -> Submission? {
    let current = query(text, home: home)
    guard !current.target.isEmpty, readable, !blocked(current.target, home: home) else { return nil }
    if added.contains(current.target) { return .added(current.target) }
    if current.filter.isEmpty || rows.contains(where: { $0.name == current.filter }) {
      return .existing(current.target)
    }
    return .create(current.target)
  }

  public static func trim(_ path: String) -> String {
    let value = normalize(path)
    guard value != "/" else { return value }
    var trimmed = Substring(value)
    while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
  }

  static func canonical(_ path: String) -> String {
    let parts = normalize(path).split(separator: "/").reduce(into: [Substring]()) { output, part in
      if part == "." { return }
      if part == ".." {
        _ = output.popLast()
        return
      }
      output.append(part)
    }
    return "/" + parts.joined(separator: "/")
  }

  private static func normalize(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(
      of: "/{2,}", with: "/", options: .regularExpression)
  }
}

extension OpenCodeClient {
  /// The server process's home; V2 does not publish it, so the custom plugin reports it.
  public func homeDirectory() async throws -> String {
    struct Output: Decodable { let path: String }
    let output: Output = try await rpc("custom.directories", "home", input: Empty())
    return output.path
  }

  public func defaultDirectory() async throws -> String {
    try await location(directory: nil).directory
  }

  /// Resolving a Location registers its folder as a server project, as the web's sidebar does on open.
  @discardableResult
  public func location(directory: String?) async throws -> ResolvedLocation {
    try await get(
      "/api/location",
      query: directory.map { [URLQueryItem(name: "location[directory]", value: $0)] } ?? [])
  }

  public func directories(at path: String) async throws -> [ProjectExplorer.Entry] {
    try await listDirectory(path).filter { $0.kind == .directory }.map {
      ProjectExplorer.Entry(name: $0.name, absolute: $0.absolute)
    }
  }

  /// Creates only the final segment, like the web's "Create and add".
  public func createDirectory(_ path: String) async throws -> String {
    struct Input: Encodable { let path: String }
    struct Output: Decodable { let path: String }
    let output: Output = try await rpc("custom.directories", "create", input: Input(path: path))
    return output.path
  }
}

public struct ResolvedLocation: Decodable, Sendable {
  public let directory: String
}
