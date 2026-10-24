import Foundation

/// A Mac app offered by an app MCP, mirroring `AppMentions.App` of the `custom.app-mentions` RPC.
public struct ComposerApp: Codable, Sendable, Equatable {
  public let server: String
  public let name: String
  public let path: String?
  public let bundleID: String
  public let running: Bool
  public init(server: String, name: String, path: String? = nil, bundleID: String, running: Bool) {
    self.server = server
    self.name = name
    self.path = path
    self.bundleID = bundleID
    self.running = running
  }
  /// The MCP servers whose connection makes apps mentionable.
  public static let servers = ["codex-computer-use", "safari-devtools"]
  public var isSafariDevTools: Bool { server == "safari-devtools" && bundleID == "mcp.safari-devtools" }
  public var detail: [String: JSONValue] {
    var value: [String: JSONValue] = [
      "server": .string(server), "name": .string(name), "bundleID": .string(bundleID),
      "running": .bool(running),
    ]
    if let path { value["path"] = .string(path) }
    return value
  }
  public var token: ComposerToken {
    .init(kind: .app, id: "\(server):\(bundleID)", text: "@\(name)", detail: detail)
  }
  public init?(detail: [String: JSONValue]) {
    guard let server = detail["server"]?.string, let name = detail["name"]?.string,
      let bundleID = detail["bundleID"]?.string
    else { return nil }
    self.init(
      server: server, name: name, path: detail["path"]?.string, bundleID: bundleID,
      running: detail["running"]?.bool ?? false)
  }
  /// The web's `formatAppContext`, appended to the prompt text so the agent knows which MCP to use.
  public var context: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? name
    if isSafariDevTools {
      return
        "Safari DevTools selected by the user: \(json). Use only the native \(server) MCP tools, which operate in Safari's isolated automation window; do not use codex-computer-use or silently fall back to the user's ordinary Safari. If no automation window exists, begin with navigate_to_url because list_tabs and create_tab may error before initial navigation. Safari WebDriver supports a single active session; if it is already in use, report a clear conflict instead of touching personal Safari."
    }
    return
      "Computer use app selected by the user: \(json). Use its bundleID as the app argument to \(server) tools."
  }
}

/// What app mentions to list for a Location: `enabled` holds the app MCP servers that are (or, for a
/// Location that does not exist yet, will be) enabled; nil means the MCP state is not known yet.
public struct ComposerAppScope: Hashable, Sendable {
  public let server: String
  public let directory: String
  public let enabled: [String]?
  /// A new chat or worktree only records MCP intents, so the server must be told which will be enabled.
  public let intent: Bool
  public init(server: String, directory: String, enabled: [String]?, intent: Bool = false) {
    self.server = server
    self.directory = directory
    self.enabled = enabled.map { $0.filter(ComposerApp.servers.contains).sorted() }
    self.intent = intent
  }
  public static func enabled(_ servers: [MCPServer]) -> [String] {
    servers.filter { $0.status.status == .connected }.map(\.name)
  }
  var location: String { "\(server)\n\(directory)" }
  var none: Bool { enabled?.isEmpty == true }
}

/// Listing Computer Use apps takes seconds. One listing per server and Location is kept for a
/// minute and reused across composers; a different enabled set lists again.
public struct ComposerAppCache: Sendable {
  struct Entry: Sendable {
    let scope: ComposerAppScope
    let apps: [ComposerApp]
    let at: Date
  }
  public static let fresh: TimeInterval = 60
  public static let retry: TimeInterval = 5
  private var entries: [String: Entry] = [:]
  private var pending: [String: ComposerAppScope] = [:]
  public init() {}
  public func apps(_ scope: ComposerAppScope) -> [ComposerApp] {
    guard !scope.none, let entry = entries[scope.location], entry.scope == scope else { return [] }
    return entry.apps
  }
  /// Whether to start listing now. A known scope loads ahead of `@`; an unknown one only on `@`.
  public mutating func begin(_ scope: ComposerAppScope, open: Bool, now: Date = Date()) -> Bool {
    guard !scope.none, scope.enabled != nil || open, pending[scope.location] != scope else { return false }
    if let entry = entries[scope.location], entry.scope == scope,
      now.timeIntervalSince(entry.at) < Self.fresh
    {
      return false
    }
    pending[scope.location] = scope
    return true
  }
  /// Records a listing; nil is a failure, which keeps earlier apps and retries shortly.
  public mutating func finish(_ scope: ComposerAppScope, apps: [ComposerApp]?, now: Date = Date())
  {
    guard pending[scope.location] == scope else { return }
    pending[scope.location] = nil
    let previous = entries[scope.location].flatMap { $0.scope == scope ? $0.apps : nil } ?? []
    entries[scope.location] = Entry(
      scope: scope, apps: apps ?? previous,
      at: apps == nil ? now.addingTimeInterval(Self.retry - Self.fresh) : now)
  }
}

extension OpenCodeClient {
  public func composerApps(_ scope: ComposerAppScope) async throws -> [ComposerApp] {
    struct Input: Encodable { let enabled: [String]? }
    struct Output: Decodable { let apps: [ComposerApp] }
    let output: Output = try await rpc(
      "custom.app-mentions", "list", input: Input(enabled: scope.intent ? scope.enabled : nil),
      directory: scope.directory)
    return output.apps
  }
}
