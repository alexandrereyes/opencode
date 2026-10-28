import Foundation

public struct SessionRelativeTime: Sendable, Equatable {
  public let label: String
  public let accessibilityLabel: String
}

extension SessionList {
  public static func relativeTime(_ milliseconds: Double, now: Date = .now) -> SessionRelativeTime {
    let seconds = floor((now.timeIntervalSince1970 * 1000 - milliseconds) / 1000)
    guard seconds.isFinite, abs(milliseconds) <= 8_640_000_000_000_000 else {
      return SessionRelativeTime(label: "", accessibilityLabel: "")
    }
    let elapsed = max(0, seconds)
    let divisor: Double = elapsed < 60 ? 1 : elapsed < 3600 ? 60 : elapsed < 86400 ? 3600 : 86400
    let count = Int(floor(elapsed / divisor))
    let suffix = divisor == 1 ? "s" : divisor == 60 ? "m" : divisor == 3600 ? "h" : "d"
    let unit =
      divisor == 1 ? "segundo" : divisor == 60 ? "minuto" : divisor == 3600 ? "hora" : "dia"
    return SessionRelativeTime(
      label: "\(count)\(suffix)",
      accessibilityLabel: count == 0 ? "Agora mesmo" : "há \(count) \(unit)\(count == 1 ? "" : "s")"
    )
  }
}

public struct SessionDirectoryLabel: Sendable, Equatable {
  public let path: String
  public let branch: String?
  /// The second line of a chat listed beside repository sessions.
  public static let chats = SessionDirectoryLabel(path: "Chats", branch: nil)
  public var accessibilityLabel: String {
    if self == .chats { return "Chats" }
    return branch.map { "Diretório \(path), branch \($0)" } ?? "Diretório \(path)"
  }
  public static func abbreviate(_ directory: String, home: String?) -> String {
    if let home, !home.isEmpty {
      let root = home.hasSuffix("/") ? String(home.dropLast()) : home
      if directory == root || directory == root + "/" { return "~" }
      if directory.hasPrefix(root + "/") { return "~" + directory.dropFirst(root.count) }
    }
    let suffix = directory.split(separator: "/").suffix(2).joined(separator: "/")
    return suffix.isEmpty ? "…" : "…/" + suffix
  }
}

/// A server-bound snapshot: render-time reads never issue requests. Refresh only with the list throttle.
public struct SessionDirectoryCache: Sendable {
  public private(set) var home: String?
  public private(set) var locations: [String: LocatedDirectory] = [:]
  public init() {}

  public func refreshed(_ directories: [String], using client: OpenCodeClient) async -> Self {
    let directories = Array(Set(directories)).sorted()
    async let serverHome = home == nil ? try? client.serverHome() : home
    async let located = directories.isEmpty ? [] : try? client.locate(directories)
    var next = Self()
    next.home = await serverHome
    // A failed/unsupported read must not keep claiming an old branch is current.
    next.locations = Dictionary(
      (await located ?? []).map { ($0.directory, $0) }, uniquingKeysWith: { _, last in last })
    return next
  }

  public func label(directory: String, chatRoot: String?) -> SessionDirectoryLabel? {
    if let chatRoot, directory == chatRoot || directory.hasPrefix(chatRoot + "/") { return nil }
    let location = locations[directory]
    let branch = location?.branch.flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
    let fallback = location.flatMap {
      $0.worktree != $0.canonical ? $0.worktree.split(separator: "/").last.map(String.init) : nil
    }
    return SessionDirectoryLabel(
      path: SessionDirectoryLabel.abbreviate(directory, home: home), branch: branch ?? fallback)
  }
}

extension OpenCodeClient {
  public func serverHome() async throws -> String {
    struct Response: Decodable { let path: String }
    let response: Response = try await rpc("custom.directories", "home", input: Empty())
    return response.path
  }
}
