import Foundation

/// The Mac app's third column ("Contexto"): the session's cost, its subagents, background tasks and live
/// resources, and the "Arquivos" view over it. Everything here derives from data the iOS app already reads
/// (`custom.session-family`, `/api/shell`, `custom.resources`, `/api/vcs/diff`, `/api/fs/list`).
public enum ContextColumn {
  // MARK: Cost

  public struct Costs: Sendable, Equatable {
    public let session: Double?
    public let subagents: Double?
    public var total: Double? {
      session == nil && subagents == nil ? nil : (session ?? 0) + (subagents ?? 0)
    }
  }

  /// "Sessão" is the root's own cost; "Subagentes" is the family snapshot's descendant cost, or, without it,
  /// the sum of the loaded descendants' own costs.
  public static func costs(session: Session?, family: FamilySnapshot?, members: [Session]) -> Costs {
    let own = members.filter { $0.id != session?.id }.compactMap(\.cost)
    return Costs(session: session?.cost, subagents: family?.cost ?? (own.isEmpty ? nil : own.reduce(0, +)))
  }

  /// A subagent's cost, including the subagents it started in turn.
  public static func cost(of childID: String, members: [Session]) -> Double? {
    cost(of: childID, members: members, parents: parents(members))
  }

  /// The direct child of `rootID` that `sessionID` belongs to (itself, or the child it descends from).
  public static func branch(of sessionID: String, rootID: String, members: [Session]) -> String? {
    branch(of: sessionID, rootID: rootID, parents: parents(members), limit: members.count)
  }

  // The family's parents are indexed once per projection: rebuilding them for every member made the subagent list
  // cubic in the family's size.
  private static func parents(_ members: [Session]) -> [String: String?] {
    Dictionary(members.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
  }

  private static func cost(of childID: String, members: [Session], parents: [String: String?]) -> Double? {
    let costs = members.filter {
      $0.id == childID || branch(of: $0.id, rootID: childID, parents: parents, limit: members.count) != nil
    }.compactMap(\.cost)
    return costs.isEmpty ? nil : costs.reduce(0, +)
  }

  private static func branch(of sessionID: String, rootID: String, parents: [String: String?], limit: Int) -> String? {
    var current = sessionID
    for _ in 0..<limit + 1 {
      guard let parent = parents[current] ?? nil else { return nil }
      if parent == rootID { return current }
      current = parent
    }
    return nil
  }

  /// "99,5%": the column shows one decimal for cache hits (context has none, `ContextUsage.percent`).
  public static func percent(_ fraction: Double) -> String {
    (fraction * 100).formatted(.number.locale(Locale(identifier: "pt_BR")).grouping(.never)
      .precision(.fractionLength(1))) + "%"
  }

  /// Cache hit below this reads as a warning (amber).
  public static let cacheWarning = 0.8

  // MARK: Metrics line

  /// A subagent's Progresso (its `todowrite` list): `2/4`.
  public struct Progress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) {
      self.done = done
      self.total = total
    }
    public var label: String { "\(done)/\(total)" }
  }

  public struct Metric: Sendable, Equatable {
    public enum Kind: Sendable, Hashable { case context, tokens, cache, cost, elapsed, progress }
    public let kind: Kind
    public let text: String
    /// Context above 80% or cache below `cacheWarning`.
    public var warning = false
  }

  /// Below this width of the column's content the subagent lines drop their tokens (their tooltip keeps them).
  public static let narrowWidth = 444.0

  /// `◔ 71% · 711,3k / 1M · ⚡ 99,0% · US$ 26,95 · 20m · ☑ 2/4`: context, cache, cost, time, then Progresso. The
  /// context has no decimal and the cache one. Narrow drops the tokens when a percentage stands for the context; a
  /// model outside the catalog (no limit) keeps only its tokens, narrow too.
  public static func metrics(
    usage: ContextUsage?, cacheHit: Double?, cost: Double?, elapsed: String? = nil, progress: Progress? = nil,
    narrow: Bool = false
  ) -> [Metric] {
    let context: [Metric] = usage.map { usage in
      guard let fraction = usage.fraction else { return [Metric(kind: .tokens, text: usage.tokenLabel)] }
      return [Metric(kind: .context, text: ContextUsage.percent(fraction), warning: usage.warning)]
        + (narrow ? [] : [Metric(kind: .tokens, text: usage.tokenLabel)])
    } ?? []
    return context + [
      cacheHit.map { Metric(kind: .cache, text: percent($0), warning: $0 < cacheWarning) },
      cost.map { Metric(kind: .cost, text: narrow ? ContextUsage.compactMoney($0) : ContextUsage.money($0)) },
      elapsed.map { Metric(kind: .elapsed, text: $0) },
      progress.flatMap { $0.total > 0 ? Metric(kind: .progress, text: $0.label) : nil },
    ].compactMap { $0 }
  }

  // MARK: Subagents

  public enum Status: Sendable, Equatable {
    case starting, running, permission, question, completed, failed, interrupted, ended
    public var label: String {
      switch self {
      case .starting: "Iniciando"
      case .running: "Em execução"
      case .permission: "Pede permissão"
      case .question: "Pergunta"
      case .completed: "Concluído"
      case .failed: "Erro"
      case .interrupted: "Interrompido"
      case .ended: "Encerrado"
      }
    }
    /// Still working (or waiting for Alexandre): listed above the finished ones and never collapsed.
    public var live: Bool { [.starting, .running, .permission, .question].contains(self) }
  }

  public struct Subagent: Identifiable, Sendable {
    public let work: SessionWork
    public let session: Session?
    public let status: Status
    /// The latest measured step (`Session.context`), like the iOS agents list.
    public let usage: ContextUsage?
    /// Cache hit of the subagent's whole session (`Session.tokens`), like the header's.
    public let cacheHit: Double?
    public let cost: Double?
    public let permission: PermissionRequest?
    /// Resources the subagent (or one of its own subagents) is using right now.
    public let resources: [SessionResource]
    /// Its Progresso while it works, when the column has one for the child.
    public let progress: Progress?
    public var id: String { work.id }
  }

  public struct Subagents: Sendable {
    /// Live work, then the most recent finished rows up to `minimumShown`.
    public let shown: [Subagent]
    /// The remaining finished rows, behind "+N concluídos".
    public let hidden: [Subagent]
    public var total: Int { shown.count + hidden.count }
    public var active: Int { shown.filter(\.status.live).count }
  }

  public static let minimumShown = 5

  /// Keeps `ConversationProjection.work`'s order (running first by latest start, then finished by last run).
  /// `progress` is keyed by child session ID; like Sessões, a row shows it only while the child is live.
  public static func subagents(
    work: [SessionWork], rootID: String, members: [Session], models: [ModelInfo],
    permissions: [PermissionRequest], forms: [PendingForm], resources: [SessionResource],
    progress: [String: Progress] = [:]
  ) -> Subagents {
    let sessions = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let parents = parents(members)
    let rows = work.filter { $0.kind == .agent }.map { work -> Subagent in
      let child = work.sessionID
      let owns = { (id: String) -> Bool in
        guard let child else { return false }
        return id == child || branch(of: id, rootID: child, parents: parents, limit: members.count) != nil
      }
      let permission = permissions.first { owns($0.sessionID) }
      let status: Status =
        permission != nil ? .permission
        : forms.contains(where: { owns($0.sessionID) }) && work.live ? .question
        : status(work.state)
      let session = child.flatMap { sessions[$0] }
      let context = session?.context
      return Subagent(
        work: work, session: session, status: status,
        usage: context.flatMap { ContextUsage(tokens: $0.tokens, limit: ContextUsage.limit($0.model, models: models)) },
        cacheHit: ContextUsage.cacheHit(session?.tokens ?? context?.tokens),
        cost: child.flatMap { cost(of: $0, members: members, parents: parents) },
        permission: permission,
        resources: resources.filter { resource in
          inUse(resource) && resource.owner.map { owns($0.sessionID) } == true
        },
        progress: status.live ? child.flatMap { progress[$0] } : nil)
    }
    let live = rows.filter(\.status.live)
    let finished = rows.filter { !$0.status.live }
    let extra = max(0, minimumShown - live.count)
    return Subagents(shown: live + finished.prefix(extra), hidden: Array(finished.dropFirst(extra)))
  }

  /// `astraxhighultra · Astra 6 - ultrafast · xhigh`: the agent and the model a subagent runs with now
  /// (`SessionWork.agent` and `.model`, the child's latest ones), by their catalog names.
  public static func runLabel(_ work: SessionWork, agents: [AgentInfo], models: [ModelInfo]) -> String? {
    let agent = work.agent.map { id in agents.first { $0.id == id }?.name ?? id }
    let model = work.model.map { model in
      [models.first { $0.id == model.id && $0.providerID == model.providerID }?.name ?? model.id,
       model.variant == "default" ? nil : model.variant].compactMap { $0 }.joined(separator: " · ")
    }
    let parts = [agent, model].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func status(_ state: SessionWork.State) -> Status {
    switch state {
    case .starting: .starting
    case .running: .running
    case .completed: .completed
    case .failed: .failed
    case .interrupted: .interrupted
    case .ended: .ended
    }
  }

  // MARK: Resources

  /// An agent or Alexandre is driving it: a large live tile.
  public static func inUse(_ resource: SessionResource) -> Bool { resource.state == .agent || resource.state == .user }

  /// In use first, then free ones, then stopped ones; each by most recent use.
  public static func resources(_ resources: [SessionResource]) -> (inUse: [SessionResource], others: [SessionResource]) {
    let recent = resources.sorted { $0.lastUsedAt != $1.lastUsedAt ? $0.lastUsedAt > $1.lastUsedAt : $0.id < $1.id }
    let others = recent.filter { !inUse($0) }
    return (recent.filter(inUse), others.filter(\.state.running) + others.filter { !$0.state.running })
  }

  /// The resource's own name: the simulated device, the AVD or the page's host.
  public static func name(_ resource: SessionResource) -> String {
    switch resource.kind {
    case .iosSimulator: return resource.meta.device ?? resource.meta.name ?? resource.label
    case .androidEmulator: return resource.meta.avd?.replacingOccurrences(of: "_", with: " ") ?? resource.label
    case .chrome:
      guard let url = resource.meta.url.flatMap(URL.init(string:)), let host = url.host() else {
        return resource.meta.title ?? resource.label
      }
      return url.port.map { "\(host):\($0)" } ?? host
    case .unknown: return resource.label
    }
  }

  /// "Simulador iOS · iPhone 17 Pro", "Chrome · localhost:4177".
  public static func title(_ resource: SessionResource) -> String { resource.kind.title + " · " + name(resource) }

  /// The subagent row's chip: the device alone, or "Chrome · host" for a browser.
  public static func chip(_ resource: SessionResource) -> String {
    resource.kind == .chrome ? title(resource) : name(resource)
  }

  /// The direct subagent driving a resource, or nil when the session itself (or nobody known) uses it.
  public static func user(of resource: SessionResource, rootID: String, members: [Session]) -> String? {
    guard let owner = resource.owner, owner.sessionID != rootID else { return nil }
    return branch(of: owner.sessionID, rootID: rootID, members: members)
  }

  // MARK: Background tasks

  /// The port a dev server command listens on, for "bun run dev · :4177".
  public static func port(_ command: String) -> Int? {
    let patterns = [
      #"--port[= ](\d{2,5})\b"#, #"(?:^|\s)-p\s+(\d{2,5})\b"#, #"\bPORT=(\d{2,5})\b"#,
      #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0)?:(\d{2,5})\b"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
        let range = Range(match.range(at: 1), in: command), let port = Int(command[range]), port <= 65535
      else { continue }
      return port
    }
    return nil
  }

  /// "bun run dev · :4177": the command without the port option, which the column shows on its own.
  public static func task(_ command: String) -> (command: String, port: Int?) {
    guard let port = port(command) else { return (command, nil) }
    let stripped = command
      .replacingOccurrences(of: #"\s*(--port[= ]|-p\s+)\#(port)\b"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\bPORT=\#(port)\s+"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    return (stripped.isEmpty ? command : stripped, port)
  }

  /// "há 3 min", "há 2 h": the age of a resource's last frame.
  public static func ago(_ milliseconds: Double, now: Date = .now) -> String {
    let minutes = max(0, Int((now.timeIntervalSince1970 * 1000 - milliseconds) / 60_000))
    if minutes < 1 { return "agora" }
    if minutes < 60 { return "há \(minutes) min" }
    if minutes < 1_440 { return "há \(minutes / 60) h" }
    return "há \(minutes / 1_440) d"
  }

  // MARK: Files

  public struct FileStatus: Sendable, Equatable {
    public let change: FileExplorer.Change?
    public let additions: Int
    public let deletions: Int
  }

  public struct ChangeSummary: Sendable, Equatable {
    public let additions: Int
    public let deletions: Int
    public let files: Int
  }

  public static func summary(_ changes: [WorkingChange]) -> ChangeSummary {
    ChangeSummary(
      additions: changes.reduce(0) { $0 + $1.additions }, deletions: changes.reduce(0) { $0 + $1.deletions },
      files: changes.count)
  }

  /// Working-copy changes by absolute path (diff paths are relative to the checkout root).
  public static func statuses(_ changes: [WorkingChange], root: String) -> [String: FileStatus] {
    Dictionary(
      changes.map {
        (ProjectExplorer.canonical(root + "/" + $0.file),
         FileStatus(change: $0.status.flatMap(FileExplorer.Change.init(rawValue:)), additions: $0.additions,
           deletions: $0.deletions))
      }, uniquingKeysWith: { first, _ in first })
  }

  /// Every folder that contains a changed file, so "Só alterados" can still walk down to it.
  public static func changedFolders(_ statuses: [String: FileStatus]) -> Set<String> {
    Set(statuses.keys.flatMap { path in
      var folders: [String] = []
      var current = path
      while let parent = FileExplorer.parent(current), parent != current {
        folders.append(parent)
        current = parent
      }
      return folders
    })
  }

  public enum SortOrder: Sendable { case ascending, descending }

  /// Folders first, then files, by name in Finder order; "Só alterados" keeps changed files and their folders.
  public static func entries(
    _ entries: [DirectoryEntry], statuses: [String: FileStatus], onlyChanged: Bool, order: SortOrder = .ascending
  ) -> [DirectoryEntry] {
    let folders = onlyChanged ? changedFolders(statuses) : []
    return entries.filter { entry in
      !onlyChanged || (entry.kind == .directory ? folders.contains(entry.absolute) : statuses[entry.absolute] != nil)
    }.sorted { first, second in
      if first.kind != second.kind { return first.kind == .directory }
      let comparison = first.name.localizedStandardCompare(second.name)
      return order == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
  }

  public struct Crumb: Sendable, Equatable {
    public let name: String
    public let path: String
  }

  /// The breadcrumb from the checkout root (or `/` for a folder outside it) to `path`.
  public static func breadcrumb(_ path: String, root: String) -> [Crumb] {
    let path = ProjectExplorer.canonical(path)
    let root = ProjectExplorer.canonical(root)
    let base = path == root || path.hasPrefix(root == "/" ? "/" : root + "/") ? root : "/"
    let names = path.dropFirst(base.count).split(separator: "/").map(String.init)
    let first = Crumb(name: base == "/" ? "/" : URL(fileURLWithPath: base).lastPathComponent, path: base)
    return names.indices.reduce(into: [first]) { crumbs, index in
      crumbs.append(Crumb(name: names[index], path: ProjectExplorer.canonical(crumbs[index].path + "/" + names[index])))
    }
  }

  /// The folder's absolute path as crumbs from `/`: `/`, `Users`, `alexandre`, `Worktrees`, `app`.
  public static func absoluteBreadcrumb(_ path: String) -> [Crumb] {
    breadcrumb(path, root: "/")
  }

  /// A path that does not fit, truncated in the middle: the first crumb, an ellipsis (`nil`) and the last `keep`
  /// crumbs. Every crumb shows when `keep` covers them.
  public static func middleElided(_ crumbs: [Crumb], keep: Int) -> [Crumb?] {
    guard keep >= 1, crumbs.count > keep + 1 else { return crumbs }
    return [crumbs[0], nil] + crumbs.suffix(keep)
  }

  /// A source file as one fenced Markdown code block, so the response highlighter (highlight.js) colors it.
  /// The fence is longer than any backtick run in the file; nil when the extension names no language.
  public static func highlightSource(_ text: String, path: String) -> String? {
    guard let language = MarkdownCodeProjection.language(URL(fileURLWithPath: path).pathExtension) else { return nil }
    let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
    let fence = String(repeating: "`", count: max(3, longest + 1))
    return fence + language + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence + "\n"
  }

  /// What "Ver diff no FileMerge" needs: the file relative to its checkout, and whether HEAD has a version.
  public struct FileMergePlan: Sendable, Equatable {
    public let repository: String
    public let relative: String
    /// A new file has no HEAD version; FileMerge then compares against an empty file.
    public let added: Bool
    public var gitArguments: [String] { ["-C", repository, "show", "HEAD:" + relative] }
    /// "SessionsView (HEAD).swift", so FileMerge's title tells the two sides apart.
    public var baseName: String {
      let name = URL(fileURLWithPath: relative)
      let stem = name.deletingPathExtension().lastPathComponent
      return name.pathExtension.isEmpty ? stem + " (HEAD)" : stem + " (HEAD)." + name.pathExtension
    }
  }

  /// Only files inside the checkout have a HEAD version to compare.
  public static func fileMerge(_ path: String, root: String, status: FileStatus?) -> FileMergePlan? {
    let path = ProjectExplorer.canonical(path)
    let root = ProjectExplorer.canonical(root)
    guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
    return FileMergePlan(
      repository: root, relative: String(path.dropFirst(root == "/" ? 1 : root.count + 1)),
      added: status?.change == .added)
  }
}
