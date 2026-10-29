import Foundation

/// Espaço em disco on the Mac: the rail's level, how worktrees and the agents' leftovers are classified, what may be
/// removed and the totals. The Mac gathers the facts (git, processes, sizes) and removes; the rules live here.
public enum DiskCleanup {
  /// A change this recent keeps a leftover in place and a worktree unmarked by default.
  public static let recent: TimeInterval = 24 * 3600

  public enum Level: Sendable, Equatable { case roomy, fair, low, critical }

  /// Green above 25% free, orange below 15%, red below 5%; between 15% and 25% the bar stays neutral.
  public static func level(free: Int64, total: Int64) -> Level {
    guard total > 0 else { return .fair }
    let share = Double(free) / Double(total)
    if share < 0.05 { return .critical }
    if share < 0.15 { return .low }
    if share <= 0.25 { return .fair }
    return .roomy
  }

  /// "90 GB", "1,8 TB", "14,3 GB": binary units, like `du -h` and `df -h` in the agents' reports, one decimal
  /// below 100.
  public static func bytes(_ value: Int64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    var amount = Double(max(value, 0))
    var unit = 0
    while amount >= 1000, unit < units.count - 1 {
      amount /= 1024
      unit += 1
    }
    if unit == 0 { return "\(Int(amount)) bytes" }
    let rounded = amount < 100 ? (amount * 10).rounded() / 10 : amount.rounded()
    let text = rounded == rounded.rounded() ? String(Int(rounded))
      : String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    return text + " " + units[unit]
  }

  /// "agora", "há 3 min", "há 5 h", "há 1 dia", "há 12 dias".
  public static func ago(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "agora" }
    if seconds < 3600 { return "há \(Int(seconds / 60)) min" }
    if seconds < 86_400 { return "há \(Int(seconds / 3600)) h" }
    let days = Int(seconds / 86_400)
    return days == 1 ? "há 1 dia" : "há \(days) dias"
  }

  /// The server shares this Mac's disk when its temporary folder lies in this user's own temporary folder, a
  /// per-user, per-machine path no other computer has. Any doubt counts as remote.
  public static func local(serverTemp: String?, userTemp: String) -> Bool {
    guard let serverTemp, !serverTemp.isEmpty, !userTemp.isEmpty else { return false }
    return contains(normalized(userTemp), normalized(serverTemp))
  }

  /// `path` is `root` or lies inside it.
  public static func contains(_ root: String, _ path: String) -> Bool {
    let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    return path == root || path.hasPrefix(root + "/")
  }

  /// What this Mac's processes use, indexed once for thousands of lookups: a process uses a folder when its working
  /// folder is inside it or an argument names a path inside it (`-derivedDataPath`, an app's executable). `/var` and
  /// `/private/var` are the same folder.
  public struct ProcessUse: Sendable {
    private let folders: Set<String>

    public init(arguments: [String], directories: [String]) {
      let named = arguments.flatMap { $0.split(whereSeparator: { " \t\"'=:,".contains($0) }) }
        .filter { $0.hasPrefix("/") }.map(String.init)
      folders = Set((named + directories).flatMap { DiskCleanup.ancestors(DiskCleanup.normalized($0)) })
    }

    public func uses(_ path: String) -> Bool { folders.contains(DiskCleanup.normalized(path)) }
  }

  static func ancestors(_ path: String) -> [String] {
    var result = [path]
    var current = Substring(path)
    while let slash = current.lastIndex(of: "/"), slash != current.startIndex {
      current = current[..<slash]
      result.append(String(current))
    }
    return result
  }

  static func normalized(_ path: String) -> String {
    let path = path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  // MARK: Worktrees

  /// A session as the cleanup sees it: where it works and whether it is archived or running.
  public struct SessionLink: Sendable, Equatable {
    public let id: String
    public let directory: String
    public let root: Bool
    public let archived: Bool
    public let running: Bool
    public init(id: String, directory: String, root: Bool, archived: Bool, running: Bool) {
      self.id = id
      self.directory = directory
      self.root = root
      self.archived = archived
      self.running = running
    }
  }

  /// Sessions whose directory is the worktree or inside it. Archived ones are counted apart: they never hold the
  /// worktree (the history stays on the server), but the row says they exist.
  public static func sessions(of path: String, _ links: [SessionLink]) -> Worktree.Sessions {
    let linked = links.filter { contains(path, $0.directory) }
    let live = linked.filter { !$0.archived }
    let roots = live.filter(\.root).count
    return Worktree.Sessions(active: roots > 0 ? roots : live.count, running: live.contains(where: \.running),
      archived: linked.filter { $0.archived && $0.root }.count)
  }

  public struct Worktree: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
      /// A linked worktree of a repository: `git worktree remove` can take it.
      case worktree
      /// A repository's own checkout (a clone): never removed here.
      case clone
      /// Not a git checkout at all.
      case folder
    }
    public struct Sessions: Sendable, Equatable {
      public var active = 0
      public var running = false
      public var archived = 0
      public init(active: Int = 0, running: Bool = false, archived: Int = 0) {
        self.active = active
        self.running = running
        self.archived = archived
      }
    }

    public let path: String
    public var kind: Kind
    /// The repository's main checkout, which runs `git worktree remove`.
    public var repository: String?
    public var branch: String?
    /// `git worktree lock`, or a repository git could not read.
    public var gitLocked = false
    /// Changed and untracked files (`git status --porcelain`); nil until git answers.
    public var dirty: Int?
    /// Commits of HEAD on no remote branch; nil until git answers.
    public var unpushed: Int?
    /// HEAD is already in the base branch.
    public var integrated = false
    public var lastChange: Date?
    /// A process of this Mac works inside it.
    public var inUse = false
    public var sessions = Sessions()
    public var size: Int64?
    public var id: String { path }

    public init(path: String, kind: Kind, repository: String? = nil, branch: String? = nil) {
      self.path = path
      self.kind = kind
      self.repository = repository
      self.branch = branch
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var known: Bool { kind != .worktree || (dirty != nil && unpushed != nil) }
    public var pending: Bool { (dirty ?? 0) > 0 || (unpushed ?? 0) > 0 }
  }

  public enum Verdict: Sendable, Equatable {
    /// Never selectable: a live session, a process, a remote server, not a removable worktree, or not checked yet.
    case locked
    /// Selectable only after an explicit confirmation: uncommitted files or unsent commits.
    case confirm
    case free
  }

  public static func verdict(_ worktree: Worktree, local: Bool) -> Verdict {
    guard local, worktree.kind == .worktree, worktree.repository != nil, !worktree.gitLocked, worktree.known,
      worktree.sessions.active == 0, !worktree.inUse else { return .locked }
    return worktree.pending ? .confirm : .free
  }

  /// Marked when the sheet opens: free, measured, and untouched for a day.
  public static func preselected(_ worktree: Worktree, local: Bool, now: Date) -> Bool {
    guard verdict(worktree, local: local) == .free, let change = worktree.lastChange else { return false }
    return now.timeIntervalSince(change) >= recent
  }

  public struct Status: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case neutral, warning, working }
    public let title: String
    public let detail: String?
    public let tone: Tone
    public let locked: Bool
  }

  public static func status(_ worktree: Worktree, local: Bool, now: Date) -> Status {
    let locked = verdict(worktree, local: local) == .locked
    func plain(_ title: String, _ detail: String?) -> Status { Status(title: title, detail: detail, tone: .neutral, locked: locked) }
    let sessions = worktree.sessions
    if !local { return plain("Servidor remoto", "sessões não verificáveis") }
    if sessions.active > 0 {
      return Status(title: sessions.active == 1 ? "1 sessão" : "\(sessions.active) sessões",
        detail: sessions.running ? "trabalhando" : "sem atividade", tone: sessions.running ? .working : .neutral,
        locked: true)
    }
    switch worktree.kind {
    case .clone: return plain("Clone independente", "remova pelo Finder")
    case .folder: return plain("Não é do git", "remova pelo Finder")
    case .worktree: break
    }
    if worktree.repository == nil { return plain("Repositório sumiu", "remova pelo Finder") }
    if worktree.gitLocked { return plain("Travada no git", "git worktree unlock") }
    if worktree.inUse { return plain("Em uso", "por um processo deste Mac") }
    guard let dirty = worktree.dirty, let unpushed = worktree.unpushed else { return plain("Verificando…", nil) }
    if dirty > 0 {
      return Status(title: "\(dirty) \(dirty == 1 ? "arquivo não commitado" : "arquivos não commitados")",
        detail: unpushed > 0 ? "e \(commits(unpushed)) não \(unpushed == 1 ? "enviado" : "enviados")" : nil,
        tone: .warning, locked: false)
    }
    if unpushed > 0 {
      return Status(title: "\(commits(unpushed)) não \(unpushed == 1 ? "enviado" : "enviados")", detail: nil,
        tone: .warning, locked: false)
    }
    let title = sessions.archived > 0 ? "Só sessões arquivadas" : "Sem sessão"
    if worktree.integrated { return plain(title, "branch já integrada") }
    guard let change = worktree.lastChange else { return plain(title, nil) }
    let age = now.timeIntervalSince(change)
    if age < recent { return plain(title, "mudou " + ago(change, now: now)) }
    return plain(title, "parada " + ago(change, now: now))
  }

  private static func commits(_ count: Int) -> String { count == 1 ? "1 commit" : "\(count) commits" }

  // MARK: Agents' leftovers

  public struct Leftover: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
      case build, tests, app, log, capture, other
    }
    public let path: String
    public let kind: Kind
    /// A DerivedData's `WorkspacePath`: the checkout it was built from.
    public var origin: String?
    public var originExists = true
    public var size: Int64?
    /// The newest change inside it, from this run's measurement (nil until measured).
    public var newest: Date?
    public var inUse = false
    public var id: String { path }

    public init(path: String, kind: Kind, origin: String? = nil, originExists: Bool = true) {
      self.path = path
      self.kind = kind
      self.origin = origin
      self.originExists = originExists
    }
  }

  /// Builds, test results, copied apps and logs are rebuilt or rewritten by the next run. Captures, uploads and
  /// everything else (copied sources, database backups) may still matter: they are only shown.
  public static func automatic(_ kind: Leftover.Kind) -> Bool {
    switch kind {
    case .build, .tests, .app, .log: true
    case .capture, .other: false
    }
  }

  public static func kind(name: String, directory: Bool, derivedData: Bool) -> Leftover.Kind {
    let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
    if derivedData { return .build }
    if directory, suffix == "xcresult" { return .tests }
    if directory, suffix == "app" { return .app }
    if !directory, ["log", "trace"].contains(suffix) { return .log }
    if name == "uploads" || ["png", "jpg", "jpeg", "heic", "gif", "mov", "mp4", "webm"].contains(suffix) { return .capture }
    return .other
  }

  /// Removed by Limpar: an automatic kind, measured in this run, used by no process and unchanged for a day.
  public static func removable(_ leftover: Leftover, now: Date) -> Bool {
    guard automatic(leftover.kind), !leftover.inUse, leftover.size != nil, let newest = leftover.newest else { return false }
    return now.timeIntervalSince(newest) >= recent
  }

  /// "27 pastas, 19 de worktrees que já não existem · 3 em uso ou recentes".
  public static func summary(_ kind: Leftover.Kind, _ items: [Leftover], now: Date) -> String {
    guard !items.isEmpty else { return "nada" }
    let noun: (String, String) = switch kind {
    case .build: ("pasta", "pastas")
    case .tests: ("resultado", "resultados")
    case .app: ("app", "apps")
    case .log: ("arquivo", "arquivos")
    case .capture, .other: ("item", "itens")
    }
    var parts = ["\(items.count) \(items.count == 1 ? noun.0 : noun.1)"]
    if kind == .build {
      let orphans = items.filter { !$0.originExists }.count
      if orphans > 0 { parts[0] += ", \(orphans) de worktrees que já não existem" }
    }
    if automatic(kind) {
      let kept = items.filter { $0.size != nil && $0.newest != nil && !removable($0, now: now) }.count
      if kept > 0 { parts.append("\(kept) em uso ou \(kept == 1 ? "recente" : "recentes")") }
    }
    return parts.joined(separator: " · ")
  }

  /// A row of Sujeira dos agentes, built once per change instead of on every render.
  public struct Category: Sendable, Equatable, Identifiable {
    public let kind: Leftover.Kind
    public let count: Int
    public let size: Int64
    /// Every item measured in this run.
    public let measured: Bool
    public let removable: Int64
    public let summary: String
    public var id: Leftover.Kind { kind }
  }

  public static func categories(_ leftovers: [Leftover], now: Date) -> [Category] {
    let groups = Dictionary(grouping: leftovers, by: \.kind)
    return Leftover.Kind.allCases.compactMap { kind in
      guard let items = groups[kind] else { return nil }
      return Category(kind: kind, count: items.count, size: items.reduce(0) { $0 + ($1.size ?? 0) },
        measured: items.allSatisfy { $0.newest != nil },
        removable: items.filter { removable($0, now: now) }.reduce(0) { $0 + ($1.size ?? 0) },
        summary: summary(kind, items, now: now))
    }
  }

  // MARK: Totals

  public static func freeable(worktrees: [Worktree], selected: Set<String>, categories: [Category],
    kinds: Set<Leftover.Kind>) -> Int64 {
    worktrees.filter { selected.contains($0.path) }.reduce(0) { $0 + ($1.size ?? 0) }
      + categories.filter { kinds.contains($0.kind) }.reduce(0) { $0 + $1.removable }
  }

  /// `git worktree list --porcelain`: the first entry is the main checkout.
  public struct ListedWorktree: Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var locked = false
    public var prunable = false
    public var bare = false
  }

  public static func worktreeList(_ porcelain: String) -> [ListedWorktree] {
    porcelain.components(separatedBy: "\n\n").compactMap { block in
      let lines = block.split(separator: "\n").map(String.init)
      guard let first = lines.first, first.hasPrefix("worktree ") else { return nil }
      var entry = ListedWorktree(path: String(first.dropFirst("worktree ".count)))
      for line in lines.dropFirst() {
        if line.hasPrefix("branch ") { entry.branch = String(line.dropFirst("branch refs/heads/".count)) }
        if line == "locked" || line.hasPrefix("locked ") { entry.locked = true }
        if line == "prunable" || line.hasPrefix("prunable ") { entry.prunable = true }
        if line == "bare" { entry.bare = true }
      }
      return entry
    }
  }
}
