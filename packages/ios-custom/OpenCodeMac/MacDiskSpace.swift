import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// Espaço em disco, for the whole app: the volume's free space (the rail's bar, every few minutes), and on demand
/// the worktrees and the agents' leftovers with their sizes, measured progressively off the main thread and kept
/// between openings (and launches, in `disk-sizes.json`). Removal is `MacDiskCleaner`, after the preview.
@MainActor @Observable final class MacDiskStore {
  struct Volume: Equatable {
    let free: Int64
    let total: Int64
    let at: Date
  }

  enum Intent { case select, remove }

  let roots = MacDiskRoots.current
  private(set) var volume: Volume?
  private(set) var worktrees: [DiskCleanup.Worktree] = []
  /// Thousands of items: the sheet observes `categories`, rebuilt once per batch, instead.
  @ObservationIgnored private(set) var leftovers: [DiskCleanup.Leftover] = []
  private(set) var categories: [DiskCleanup.Category] = []
  private(set) var extras: [MacDiskExtra] = []
  /// Worktree path → the OpenCode project it belongs to, for its avatar.
  private(set) var projects: [String: Project] = [:]
  /// The connected server runs on this Mac, so its sessions say which worktrees are in use.
  private(set) var local = true
  private(set) var scanning = false
  private(set) var scannedAt: Date?
  /// Not measured (or not checked by git) in this run yet: the row says "calculando…".
  private(set) var measuring: Set<String> = []
  var selected: Set<String> = []
  var kinds: Set<DiskCleanup.Leftover.Kind> = [.build, .tests, .app, .log]
  var simulators = true
  /// A worktree with pending work waiting for the explicit confirmation, and what it was for.
  var confirming: (worktree: DiskCleanup.Worktree, intent: Intent)?
  var plan: MacDiskPlan?
  private(set) var progress: MacDiskProgress?
  /// Worktree path → the state (`fingerprint`) whose loss Alexandre confirmed. Another state, or cancelling the
  /// preview, voids it.
  @ObservationIgnored private(set) var confirmed: [String: String] = [:]
  @ObservationIgnored private var touched: Set<String> = []
  /// The sessions store (so the connection) the lists were read with.
  @ObservationIgnored private var scanned: ObjectIdentifier?
  @ObservationIgnored private var cleaning: Task<Void, Never>?
  @ObservationIgnored private var sizes: [String: Int64]
  @ObservationIgnored private var skips: [String: [String]] = [:]
  /// Leftover path → its index, for the thousands of sizes that arrive in batches.
  @ObservationIgnored private var positions: [String: Int] = [:]
  @ObservationIgnored private var parts: [String: Int64] = [:]
  @ObservationIgnored private var scan: Task<Void, Never>?
  @ObservationIgnored private var ticker: Task<Void, Never>?

  init() {
    sizes = (try? JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: MacDiskRoots.current.cache))) ?? [:]
  }

  /// The rail's bar: now and every three minutes.
  func start() {
    guard ticker == nil else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshVolume()
        try? await Task.sleep(for: .seconds(180))
      }
    }
  }

  func refreshVolume() async {
    guard let value = await MacDiskProbe.off({ MacDiskProbe.volume() }) else { return }
    volume = Volume(free: value.free, total: value.total, at: .now)
  }

  /// Opening the sheet: the volume now, and a new scan when the last one is more than ten minutes old or was read
  /// through another connection.
  func open(sessions: SessionStore) {
    Task { await refreshVolume() }
    let stale = scanned != ObjectIdentifier(sessions) || scannedAt.map { Date.now.timeIntervalSince($0) > 600 } ?? true
    guard stale, !scanning || scanned != ObjectIdentifier(sessions) else { return }
    rescan(sessions: sessions)
  }

  func rescan(sessions: SessionStore) {
    guard progress.map(\.finished) ?? true else { return }
    if scanned != ObjectIdentifier(sessions) { forget() }
    scan?.cancel()
    scanned = ObjectIdentifier(sessions)
    scan = Task { await run(sessions) }
  }

  /// Another connection: nothing read or confirmed through the previous one holds.
  private func forget() {
    worktrees = []
    projects = [:]
    selected = []
    confirmed = [:]
    touched = []
    confirming = nil
    plan = nil
    local = false
    scannedAt = nil
  }

  // MARK: Selection

  func verdict(_ worktree: DiskCleanup.Worktree) -> DiskCleanup.Verdict { DiskCleanup.verdict(worktree, local: local) }

  /// A worktree with pending work asks first (`confirming`); a locked one never changes.
  func toggle(_ worktree: DiskCleanup.Worktree) {
    touched.insert(worktree.path)
    if selected.remove(worktree.path) != nil {
      confirmed[worktree.path] = nil
      return
    }
    switch verdict(worktree) {
    case .locked: return
    case .confirm where !DiskCleanup.confirmed(worktree, by: confirmed[worktree.path]): confirming = (worktree, .select)
    case .confirm, .free: selected.insert(worktree.path)
    }
  }

  /// The confirmation holds for the state the dialog showed; if git has seen another since, it asks again.
  func confirm() {
    guard let request = confirming else { return }
    confirming = nil
    touched.insert(request.worktree.path)
    guard let current = worktrees.first(where: { $0.path == request.worktree.path }),
      current.fingerprint == request.worktree.fingerprint, let fingerprint = current.fingerprint else { return }
    confirmed[current.path] = fingerprint
    switch request.intent {
    case .select: selected.insert(current.path)
    case .remove: preview(only: current)
    }
  }

  var freeable: Int64 {
    DiskCleanup.freeable(worktrees: worktrees, selected: selected, categories: categories, kinds: kinds)
      + (simulators ? unavailableSimulators?.unavailableSize ?? 0 : 0)
  }

  var unavailableSimulators: MacDiskExtra? { extras.first { $0.kind == .simulators && !$0.unavailable.isEmpty } }

  /// The preview of Limpar: the marked worktrees, every removable leftover of the chosen kinds and, when chosen,
  /// the unavailable simulators. `only` previews a single worktree (its Remover).
  func preview(only worktree: DiskCleanup.Worktree? = nil) {
    guard let scanned else { return }
    if let worktree {
      switch verdict(worktree) {
      case .locked: return
      case .confirm where !DiskCleanup.confirmed(worktree, by: confirmed[worktree.path]):
        confirming = (worktree, .remove)
        return
      case .confirm, .free: break
      }
      plan = MacDiskPlan(worktrees: [worktree], leftovers: [], simulators: nil, confirmed: confirmed, store: scanned)
      return
    }
    plan = MacDiskPlan(worktrees: worktrees.filter { selected.contains($0.path) },
      leftovers: leftovers.filter { kinds.contains($0.kind) && DiskCleanup.removable($0, now: .now) },
      simulators: simulators ? unavailableSimulators : nil, confirmed: confirmed, store: scanned)
  }

  /// Cancelar in the preview: the confirmations given for its worktrees end with it.
  func cancelPreview() {
    for worktree in plan?.worktrees ?? [] where worktree.pending {
      confirmed[worktree.path] = nil
      selected.remove(worktree.path)
    }
    plan = nil
  }

  /// Apagar in the preview; Parar (`stop`) ends it before the next item.
  func startCleaning(_ plan: MacDiskPlan, sessions: SessionStore) {
    guard cleaning == nil else { return }
    cleaning = Task {
      await clean(plan, sessions: sessions)
      cleaning = nil
    }
  }

  func stop() { cleaning?.cancel() }

  /// Runs the approved plan one item at a time. Before each worktree the sessions are read from the server again
  /// (a failed read stops everything), the server must still be this Mac's, and the processes are read again; each
  /// leftover gets a fresh process list too. The results go to the log; the bar and the sheet are refreshed.
  func clean(_ plan: MacDiskPlan, sessions: SessionStore) async {
    #if DEBUG
    // The survey reads this Mac's real folders: it never removes anything.
    if MacDiskChecks.survey != nil { return }
    #endif
    guard progress?.finished ?? true else { return }
    progress = MacDiskProgress(total: plan.count)
    await refreshVolume()
    progress?.freeBefore = volume?.free
    let root = roots.temp
    var queue = plan.worktrees.map { MacDiskItem.worktree($0) } + plan.leftovers.map { MacDiskItem.leftover($0) }
    if let simulators = plan.simulators, !roots.fixture { queue.append(.simulators(simulators)) }
    for (index, item) in queue.enumerated() {
      progress?.current = item.name
      #if DEBUG
      await MacDiskFixture.beforeRemoval?(item.path)
      #endif
      if let reason = await interruption(plan, sessions: sessions) {
        progress?.stopped = reason
        for rest in queue[index...] { record(rest.kept(reason)) }
        break
      }
      guard let processes = await MacDiskProbe.off({ MacDiskProbe.processes() }) else {
        progress?.stopped = "não deu para ler os processos deste Mac"
        for rest in queue[index...] { record(rest.kept("parado: não deu para ler os processos")) }
        break
      }
      switch item {
      case .worktree(let worktree):
        if roots.fixture, !DiskCleanup.contains(roots.userTemp, worktree.path) {
          record(item.kept("fora do fixture"))
          continue
        }
        let links: [DiskCleanup.SessionLink]
        do { links = try await currentLinks(sessions) } catch {
          let reason = "não deu para ler as sessões do servidor"
          progress?.stopped = reason
          for rest in queue[index...] { record(rest.kept("parado: \(reason)")) }
          break
        }
        guard await isLocal(sessions) else {
          let reason = "o servidor não está mais neste Mac ou não respondeu"
          progress?.stopped = reason
          for rest in queue[index...] { record(rest.kept("parado: \(reason)")) }
          break
        }
        record(await MacDiskCleaner.remove(worktree, confirmed: plan.confirmed[worktree.path], links: links,
          processes: processes))
      case .leftover(let leftover):
        record(await MacDiskCleaner.remove(leftover, root: root, processes: processes))
      case .simulators(let simulators):
        record(await MacDiskCleaner.removeUnavailableSimulators(simulators))
      }
      if progress?.stopped != nil { break }
    }
    let repositories = Set(plan.worktrees.compactMap(\.repository))
    await MacDiskCleaner.prune(Array(repositories))
    let lines = progress?.lines ?? []
    MacDiskCleaner.log(lines, to: roots.log)
    let removed = Set(lines.filter(\.removed).map(\.path))
    selected.subtract(removed)
    for path in plan.worktrees.map(\.path) { confirmed[path] = nil }
    // The server's worktree inventory drops checkouts removed outside OpenCode on refresh.
    if !roots.fixture {
      for project in sessions.projects where repositories.contains(MacDiskProbe.real(project.canonical)) {
        _ = try? await sessions.client.refreshedWorktrees(projectID: project.id)
      }
    }
    await refreshVolume()
    progress?.freeAfter = volume?.free
    progress?.current = nil
    progress?.finished = true
    rescan(sessions: sessions)
  }

  /// Parar, or a connection other than the one the plan was read with.
  private func interruption(_ plan: MacDiskPlan, sessions: SessionStore) async -> String? {
    if Task.isCancelled { return "interrompido por você" }
    if plan.store != ObjectIdentifier(sessions) || scanned != plan.store { return "a conexão com o servidor mudou" }
    return nil
  }

  func finish() {
    plan = nil
    progress = nil
  }

  private func record(_ line: MacDiskCleaner.Line) {
    progress?.lines.append(line)
    progress?.done += 1
  }

  // MARK: Scan

  private struct Job: Sendable {
    enum Target: Sendable { case worktree, leftover, extra(MacDiskExtra.Kind), unavailable }
    let target: Target
    let path: String
    var skip: [String] = []
  }

  private func run(_ sessions: SessionStore) async {
    scanning = true
    defer { scanning = false }
    await refreshVolume()
    let roots = roots
    local = await isLocal(sessions)
    let unresolved = local ? links(sessions) : []
    let links = await MacDiskProbe.off { unresolved.map(\.resolved) }
    // The DEBUG fixture's projects name real repositories: its scan stays inside the fixture folder.
    let repositories = roots.fixture ? [] : Array(Set(sessions.projects.flatMap { [$0.canonical] + $0.sandboxes }))
    // Without a process list everything counts as in use.
    let processes = await MacDiskProbe.off { MacDiskProbe.processes() }
    let used: @Sendable (String) -> Bool = { processes?.uses($0) ?? true }
    // The temporary folder takes longer to list: the worktrees show (and git runs) meanwhile.
    async let temp = MacDiskProbe.off { MacDiskProbe.leftovers(root: roots.temp) }
    async let extra = MacDiskProbe.off {
      MacDiskProbe.extras(roots, processes: processes ?? MacDiskProcesses(commands: [], directories: []))
    }
    let found = await MacDiskProbe.off { MacDiskProbe.worktrees(folder: roots.worktrees, repositories: repositories) }
    guard !Task.isCancelled else { return }

    // The previous facts show until git answers again; a confirmation still needs the fingerprint to match.
    let previous = Dictionary(worktrees.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    worktrees = found.map { found in
      var worktree = found
      if let old = previous[found.path] {
        worktree.dirty = old.dirty
        worktree.unpushed = old.unpushed
        worktree.ignored = old.ignored
        worktree.submodules = old.submodules
        worktree.fingerprint = old.fingerprint
        worktree.integrated = old.integrated
        worktree.lastChange = old.lastChange
        worktree.size = old.size
      }
      worktree.size = worktree.size ?? sizes[found.path]
      worktree.sessions = DiskCleanup.sessions(of: found.path, links)
      worktree.inUse = used(found.path)
      return worktree
    }
    projects = Dictionary(worktrees.compactMap { worktree in
      sessions.projects.first { project in
        MacDiskProbe.real(project.canonical) == worktree.repository || project.sandboxes.contains(worktree.path)
          || project.worktrees?.contains { $0.directory == worktree.path } == true
      }.map { (worktree.path, $0) }
    }, uniquingKeysWith: { a, _ in a })
    measuring = Set(worktrees.map(\.path))
    reconcile()

    // Git first (seconds), then sizes: worktrees, the temporary folder, then the large shared folders.
    let checks = worktrees.filter { $0.kind == .worktree && $0.repository != nil }
    let bases = Dictionary(uniqueKeysWithValues: await MacDiskProbe.off {
      Set(checks.compactMap(\.repository)).map { ($0, MacDiskProbe.bases($0)) }
    })
    await MacDiskProbe.parallel(checks, width: 6, work: { MacDiskProbe.facts($0, bases: bases[$0.repository ?? ""] ?? []) }) {
      [weak self] batch in await self?.applyFacts(batch)
    }
    let discovered = await (temp, extra)
    guard !Task.isCancelled else { return }
    let cached = sizes
    leftovers = await MacDiskProbe.off {
      discovered.0.items.map { found in
        var leftover = found
        leftover.size = cached[found.path]
        leftover.inUse = used(found.path)
        return leftover
      }
    }
    skips = discovered.0.skips
    positions = Dictionary(leftovers.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
    categories = DiskCleanup.categories(leftovers, now: .now)
    extras = discovered.1.map { found in
      var extra = found
      extra.size = sizes["extra:" + found.kind.rawValue]
      return extra
    }
    parts = [:]
    measuring.formUnion(leftovers.map(\.path) + extras.map { "extra:" + $0.kind.rawValue })
    let jobs = worktrees.map { Job(target: .worktree, path: $0.path) }
      + leftovers.map { Job(target: .leftover, path: $0.path, skip: skips[$0.path] ?? []) }
      + extras.flatMap { extra in
        extra.paths.map { Job(target: .extra(extra.kind), path: $0) }
          + extra.unavailable.map { Job(target: .unavailable, path: $0) }
      }
    await MacDiskProbe.parallel(jobs, width: 4, work: { job in (job, MacDiskProbe.measure(job.path, skip: job.skip)) }) {
      [weak self] batch in await self?.applySizes(batch)
    }
    guard !Task.isCancelled else { return }
    for extra in extras where measuring.contains("extra:" + extra.kind.rawValue) {
      setExtra(extra.kind) { $0.size = 0 }
    }
    measuring.removeAll()
    scannedAt = .now
    let cache = sizes
    let url = roots.cache
    Task.detached(priority: .utility) {
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }
  }

  private func applyFacts(_ batch: [DiskCleanup.Worktree]) {
    for fresh in batch {
      guard let index = worktrees.firstIndex(where: { $0.path == fresh.path }) else { continue }
      var worktree = worktrees[index]
      worktree.dirty = fresh.dirty
      worktree.unpushed = fresh.unpushed
      worktree.ignored = fresh.ignored
      worktree.submodules = fresh.submodules
      worktree.fingerprint = fresh.fingerprint
      worktree.integrated = fresh.integrated
      worktree.gitLocked = fresh.gitLocked
      worktree.lastChange = [worktree.lastChange, fresh.lastChange].compactMap { $0 }.max()
      worktrees[index] = worktree
    }
    reconcile()
  }

  private func applySizes(_ batch: [(Job, MacDiskProbe.Measure?)]) {
    defer {
      if batch.contains(where: { if case .leftover = $0.0.target { true } else { false } }) {
        categories = DiskCleanup.categories(leftovers, now: .now)
      }
      reconcile()
    }
    for (job, measure) in batch {
      guard let measure else { continue }
      switch job.target {
      case .worktree:
        guard let index = worktrees.firstIndex(where: { $0.path == job.path }) else { continue }
        worktrees[index].size = measure.bytes
        worktrees[index].lastChange = [worktrees[index].lastChange, measure.newest].compactMap { $0 }.max()
        sizes[job.path] = measure.bytes
        measuring.remove(job.path)
      case .leftover:
        guard let index = positions[job.path], leftovers.indices.contains(index) else { continue }
        leftovers[index].size = measure.bytes
        leftovers[index].newest = measure.newest ?? .distantPast
        leftovers[index].complete = measure.complete
        sizes[job.path] = measure.bytes
        measuring.remove(job.path)
      case .extra(let kind):
        parts[job.path] = measure.bytes
        guard let extra = extras.first(where: { $0.kind == kind }), extra.paths.allSatisfy({ parts[$0] != nil })
        else { continue }
        let total = extra.paths.reduce(0) { $0 + (parts[$1] ?? 0) }
        setExtra(kind) { $0.size = total }
        sizes["extra:" + kind.rawValue] = total
        measuring.remove("extra:" + kind.rawValue)
      case .unavailable:
        parts[job.path] = measure.bytes
        guard let extra = unavailableSimulators, extra.unavailable.allSatisfy({ parts[$0] != nil }) else { continue }
        setExtra(.simulators) { $0.unavailableSize = extra.unavailable.reduce(0) { $0 + (parts[$1] ?? 0) } }
      }
    }
  }

  private func setExtra(_ kind: MacDiskExtra.Kind, _ change: (inout MacDiskExtra) -> Void) {
    guard let index = extras.firstIndex(where: { $0.kind == kind }) else { return }
    change(&extras[index])
  }

  /// Keeps only selectable rows marked, and marks the ones that became fully known (git and size) and qualify, unless
  /// Alexandre already touched them. A confirmation given for another state is dropped with its mark.
  private func reconcile() {
    let now = Date.now
    for worktree in worktrees {
      switch verdict(worktree) {
      case .locked:
        selected.remove(worktree.path)
        confirmed[worktree.path] = nil
      case .confirm where !DiskCleanup.confirmed(worktree, by: confirmed[worktree.path]):
        selected.remove(worktree.path)
        confirmed[worktree.path] = nil
      case .confirm: break
      case .free:
        guard !touched.contains(worktree.path), !measuring.contains(worktree.path) else { continue }
        if DiskCleanup.preselected(worktree, local: local, now: now) {
          selected.insert(worktree.path)
        } else {
          selected.remove(worktree.path)
        }
      }
    }
  }

  // MARK: Sessions

  /// Every session the server knows, archived or not, with where it works (`resolved` off the main thread).
  private func links(_ sessions: SessionStore) -> [DiskCleanup.SessionLink] {
    #if DEBUG
    if roots.fixture { return MacDiskFixture.links(roots) }
    #endif
    let running = sessions.active
    return sessions.entries.map(\.session).map { session in
      DiskCleanup.SessionLink(id: session.id, directory: session.location.directory, root: session.parentID == nil,
        archived: session.time.archived != nil, running: running.contains(session.id))
    } + sessions.archived.map { session in
      DiskCleanup.SessionLink(id: session.id, directory: session.location.directory, root: session.parentID == nil,
        archived: true, running: false)
    }
  }

  /// Read from the server now, never from the store's last list (which may be old, or loading, or have failed):
  /// any failure throws, and the cleanup stops.
  private func currentLinks(_ sessions: SessionStore) async throws -> [DiskCleanup.SessionLink] {
    #if DEBUG
    if roots.fixture {
      if MacDiskFixture.sessionsFail { throw ClientError.operation("fixture") }
      return MacDiskFixture.links(roots)
    }
    #endif
    let client = sessions.client
    async let navigation = client.navigation()
    async let archived = client.archivedSessions()
    async let active = client.active()
    let (entries, archives, states) = try await (navigation, archived, active)
    let running = Set(states.filter { $0.value.isRunning }.map(\.key))
    let links = entries.map(\.session).map { session in
      DiskCleanup.SessionLink(id: session.id, directory: session.location.directory, root: session.parentID == nil,
        archived: session.time.archived != nil, running: running.contains(session.id))
    } + archives.map { session in
      DiskCleanup.SessionLink(id: session.id, directory: session.location.directory, root: session.parentID == nil,
        archived: true, running: false)
    }
    return await MacDiskProbe.off { links.map(\.resolved) }
  }

  private func isLocal(_ sessions: SessionStore) async -> Bool {
    if roots.fixture { return true }
    guard let info = try? await sessions.client.info() else { return false }
    return DiskCleanup.local(serverTemp: info.paths.map { MacDiskProbe.real($0.tmp) }, userTemp: roots.userTemp)
  }
}

/// One item of a cleanup, in order: worktrees, leftovers, then the unavailable simulators.
private enum MacDiskItem {
  case worktree(DiskCleanup.Worktree)
  case leftover(DiskCleanup.Leftover)
  case simulators(MacDiskExtra)

  var path: String {
    switch self {
    case .worktree(let worktree): worktree.path
    case .leftover(let leftover): leftover.path
    case .simulators(let extra): "\(extra.unavailable.count) aparelhos"
    }
  }

  var name: String {
    switch self {
    case .worktree(let worktree): worktree.name
    case .leftover(let leftover): URL(fileURLWithPath: leftover.path).lastPathComponent
    case .simulators: "Simuladores indisponíveis"
    }
  }

  func kept(_ reason: String) -> MacDiskCleaner.Line {
    switch self {
    case .worktree(let worktree):
      MacDiskCleaner.Line(kind: "worktree", path: worktree.path, bytes: worktree.size ?? 0, removed: false, reason: reason)
    case .leftover(let leftover):
      MacDiskCleaner.Line(kind: leftover.kind.rawValue, path: leftover.path, bytes: leftover.size ?? 0, removed: false,
        reason: reason)
    case .simulators(let extra):
      MacDiskCleaner.Line(kind: "simuladores indisponíveis", path: path, bytes: extra.unavailableSize ?? 0,
        removed: false, reason: reason)
    }
  }
}

extension DiskCleanup.SessionLink {
  /// The directory's real path, as the scan's paths are.
  var resolved: Self {
    Self(id: id, directory: MacDiskProbe.real(directory), root: root, archived: archived, running: running)
  }
}

#if DEBUG
/// `-OpenCodeMacDiskFixture <folder>`: `sessions.json` in it lists the fixture's sessions
/// (`[{"id","directory","archived","running"}]`), instead of the server's.
enum MacDiskFixture {
  struct Entry: Decodable { let id: String; let directory: String; let archived: Bool; let running: Bool }
  /// The fixture's server stops answering for sessions (`MacDiskChecks`).
  @MainActor static var sessionsFail = false
  /// Runs before each item's checks during a cleanup, so `MacDiskChecks` can change the world mid-run.
  @MainActor static var beforeRemoval: (@MainActor (String) async -> Void)?

  static func links(_ roots: MacDiskRoots) -> [DiskCleanup.SessionLink] {
    let url = URL(fileURLWithPath: roots.userTemp + "/sessions.json")
    let entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
    return entries.map {
      DiskCleanup.SessionLink(id: $0.id, directory: MacDiskProbe.real($0.directory), root: true, archived: $0.archived,
        running: $0.running)
    }
  }
}
#endif
