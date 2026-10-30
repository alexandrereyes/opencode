import Foundation

/// Arquivos, on the Mac (the panel's tree) and on the iPhone (the viewer's drawer): the session's folder as an
/// expandable tree with "Filtrar arquivos" and "Todos · Alterados". Folders are listed on demand
/// (`/api/fs/list`); Alterados is drawn from the working-copy changes alone, so it needs no listing.
public struct FileTree: Equatable, Sendable {
  public struct Row: Equatable, Sendable, Identifiable {
    public let entry: DirectoryEntry
    public let depth: Int
    /// A folder shown open: expanded, or opened by the filter or by Alterados.
    public let open: Bool
    public var id: String { entry.absolute }
    public var directory: Bool { entry.kind == .directory }
  }

  /// The tree's top: the session folder, or the folder a link or the breadcrumb opened outside it.
  public private(set) var root: String
  public private(set) var listings: [String: [DirectoryEntry]] = [:]
  public private(set) var expanded: Set<String> = []

  public init(root: String) { self.root = ProjectExplorer.canonical(root) }

  /// Whether `path` is `folder` or lies below it.
  public static func contains(_ folder: String, _ path: String) -> Bool {
    let folder = ProjectExplorer.canonical(folder)
    let path = ProjectExplorer.canonical(path)
    return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
  }

  public mutating func store(_ entries: [DirectoryEntry], in folder: String) {
    listings[ProjectExplorer.canonical(folder)] = entries
  }

  public mutating func toggle(_ folder: String) {
    let folder = ProjectExplorer.canonical(folder)
    if expanded.remove(folder) == nil { expanded.insert(folder) }
  }

  public mutating func setExpanded(_ folder: String, _ open: Bool) {
    let folder = ProjectExplorer.canonical(folder)
    if open { expanded.insert(folder) } else { expanded.remove(folder) }
  }

  /// Opens every folder from the top down to `path` (the folder itself, or a file's folder): a link from the
  /// conversation lands with its file visible. A path outside the tree makes its folder the new top. Returns the
  /// folders still to list, top first.
  @discardableResult
  public mutating func reveal(_ path: String, directory: Bool = false) -> [String] {
    let path = ProjectExplorer.canonical(path)
    let folder = directory ? path : FileExplorer.parent(path) ?? "/"
    if !Self.contains(root, folder) { root = folder }
    var chain = [folder]
    while let last = chain.last, last != root, let parent = FileExplorer.parent(last) { chain.append(parent) }
    chain.reverse()
    expanded.formUnion(chain.dropFirst())
    return chain.filter { listings[$0] == nil }
  }

  /// The top and every expanded folder below it whose listing has not arrived.
  public var unlisted: [String] {
    ([root] + expanded.filter { $0 != root && Self.contains(root, $0) }.sorted())
      .filter { listings[$0] == nil }
  }

  /// The visible rows, depth first: folders before files, each by name in Finder order. A filter keeps the names
  /// that contain it (ignoring case and accents) and opens the folders leading to them; a folder whose own name
  /// matches keeps its whole listing. Alterados keeps changed files with their folders, all open.
  public func rows(statuses: [String: ContextColumn.FileStatus], onlyChanged: Bool, filter: String) -> [Row] {
    let filter = filter.trimmingCharacters(in: .whitespaces)
    let changed = onlyChanged ? Self.changedListings(statuses, root: root) : [:]
    let source = onlyChanged ? changed : listings
    func children(_ folder: String) -> [DirectoryEntry] {
      ContextColumn.entries(source[folder] ?? [], statuses: statuses, onlyChanged: false)
    }
    func matches(_ entry: DirectoryEntry, depth: Int = 0) -> Bool {
      if entry.name.localizedStandardContains(filter) { return true }
      guard entry.kind == .directory, depth < 32 else { return false }
      return children(entry.absolute).contains { matches($0, depth: depth + 1) }
    }
    func walk(_ folder: String, depth: Int, matched: Bool) -> [Row] {
      children(folder).flatMap { entry -> [Row] in
        let own = filter.isEmpty || matched || entry.name.localizedStandardContains(filter)
        guard own || matches(entry) else { return [] }
        guard entry.kind == .directory else { return [Row(entry: entry, depth: depth, open: false)] }
        let open = onlyChanged || expanded.contains(entry.absolute) || (!filter.isEmpty && !own)
        return [Row(entry: entry, depth: depth, open: open)]
          + (open ? walk(entry.absolute, depth: depth + 1, matched: own && !filter.isEmpty) : [])
      }
    }
    return walk(root, depth: 0, matched: false)
  }

  /// Alterados as listings: each changed file under the top and every folder leading to one.
  static func changedListings(_ statuses: [String: ContextColumn.FileStatus], root: String) -> [String: [DirectoryEntry]] {
    let files = statuses.keys.filter { $0 != root && contains(root, $0) }
    let folders = ContextColumn.changedFolders(statuses).filter { $0 != root && contains(root, $0) }
    let entries = files.map { DirectoryEntry(name: URL(fileURLWithPath: $0).lastPathComponent, absolute: $0, kind: .file) }
      + folders.map { DirectoryEntry(name: URL(fileURLWithPath: $0).lastPathComponent, absolute: $0, kind: .directory) }
    return Dictionary(grouping: entries) { FileExplorer.parent($0.absolute) ?? "/" }
  }
}

/// ‹ and › of Arquivos: the files opened one after another, like a browser's back and forward.
public struct FileHistory: Equatable, Sendable {
  public private(set) var back: [String] = []
  public private(set) var forward: [String] = []
  public private(set) var current: String?
  public static let limit = 50

  public init() {}

  public var canGoBack: Bool { !back.isEmpty }
  public var canGoForward: Bool { !forward.isEmpty }

  /// Opening another file (from the tree, a link, Recentes or the sibling keys) drops what was ahead.
  public mutating func visit(_ path: String) {
    guard path != current else { return }
    if let current { back = Array((back + [current]).suffix(Self.limit)) }
    forward = []
    current = path
  }

  public mutating func goBack() -> String? {
    guard let previous = back.popLast() else { return nil }
    if let current { forward.append(current) }
    current = previous
    return previous
  }

  public mutating func goForward() -> String? {
    guard let next = forward.popLast() else { return nil }
    if let current { back.append(current) }
    current = next
    return next
  }
}

/// Recentes of Arquivos: the files last opened under one session folder on one server, newest first. They are
/// kept per folder rather than per session (sessions in the same checkout look at the same files) and survive a
/// relaunch; each device keeps its own.
public struct FileRecents: Codable, Equatable, Sendable {
  public private(set) var paths: [String] = []
  public static let limit = 8

  public init(paths: [String] = []) { self.paths = Array(paths.prefix(Self.limit)) }

  public mutating func add(_ path: String) {
    paths.removeAll { $0 == path }
    paths.insert(path, at: 0)
    paths = Array(paths.prefix(Self.limit))
  }

  public static func load(server: URL, directory: String, defaults: UserDefaults) -> Self {
    guard let data = defaults.data(forKey: key(server, directory)),
      let recents = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return recents
  }

  public func save(server: URL, directory: String, defaults: UserDefaults) {
    defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(server, directory))
  }

  private static func key(_ server: URL, _ directory: String) -> String {
    "OpenCodeFileRecents.\(server.absoluteString).\(ProjectExplorer.canonical(directory))"
  }
}
