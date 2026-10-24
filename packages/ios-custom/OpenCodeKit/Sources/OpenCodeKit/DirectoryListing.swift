import Foundation

/// One child returned by `GET /api/fs/list`, shared by the project and session file explorers.
public struct DirectoryEntry: Equatable, Sendable, Identifiable {
  public enum Kind: String, Sendable { case file, directory }
  public let name: String
  public let absolute: String
  public let kind: Kind
  public var id: String { absolute }
  public init(name: String, absolute: String, kind: Kind) {
    self.name = name
    self.absolute = absolute
    self.kind = kind
  }
}

/// The session file explorer: the web's session file tree (`app-custom/src/session/files`) as folder navigation.
public enum FileExplorer {
  public enum Change: String, Sendable {
    case added, deleted, modified
    /// The web tree's change letters.
    public var label: String {
      switch self {
      case .added: "A"
      case .deleted: "D"
      case .modified: "M"
      }
    }
  }

  /// Unlike the web tree, which stops at the session directory, `../` continues up to the filesystem root.
  public static func parent(_ path: String) -> String? {
    let value = ProjectExplorer.canonical(path)
    guard value != "/" else { return nil }
    return ProjectExplorer.canonical(value + "/..")
  }

  /// Working-copy diff paths are relative to the checkout root, even for a Session in a subdirectory.
  public static func changes(_ changes: [WorkingChange], root: String) -> [String: Change] {
    Dictionary(
      changes.compactMap { change in
        change.status.flatMap(Change.init(rawValue:)).map {
          (ProjectExplorer.canonical(root + "/" + change.file), $0)
        }
      }, uniquingKeysWith: { first, _ in first })
  }
}

extension OpenCodeClient {
  /// `path` may be absolute and outside `location`; listing never switches Location. The server orders
  /// directories first, then files, each by `localeCompare`, includes dotfiles and omits symlinks.
  public func listDirectory(_ path: String, location: String? = nil) async throws -> [DirectoryEntry] {
    struct Response: Decodable {
      let location: ResolvedLocation
      let data: [Item]
      struct Item: Decodable {
        let path: String
        let type: String
      }
    }
    let response: Response = try await get(
      "/api/fs/list",
      query: [URLQueryItem(name: "path", value: path)]
        + (location.map { [URLQueryItem(name: "location[directory]", value: $0)] } ?? []))
    // Entry paths stay relative to the requested Location, including `../` for outside folders.
    return response.data.compactMap { item in
      guard let kind = DirectoryEntry.Kind(rawValue: item.type) else { return nil }
      let absolute = ProjectExplorer.canonical(response.location.directory + "/" + item.path)
      return DirectoryEntry(name: URL(fileURLWithPath: absolute).lastPathComponent, absolute: absolute, kind: kind)
    }
  }

  /// The web explorer's search: ranked files across the Location, which respects ignore files unlike listing.
  public func findFiles(_ query: String, location: String) async throws -> [String] {
    let response: DataResponse<[ComposerFile]> = try await get("/api/fs/find", query: [
      URLQueryItem(name: "location[directory]", value: location),
      URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "file"),
      URLQueryItem(name: "limit", value: "200"),
    ])
    return response.data.filter { $0.type == "file" }.map {
      ProjectExplorer.canonical(location + "/" + $0.path)
    }
  }
}
