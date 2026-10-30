import Foundation
import OpenCodeKit

/// What Limpar removes, as approved in the preview. Every item is checked again right before it goes.
struct MacDiskPlan: Identifiable {
  let id = UUID()
  let worktrees: [DiskCleanup.Worktree]
  let leftovers: [DiskCleanup.Leftover]
  /// The unavailable simulators (`xcrun simctl delete unavailable`), when chosen.
  let simulators: MacDiskExtra?
  /// Worktree path → the state whose loss was confirmed (`Worktree.fingerprint`). It holds for that state only.
  let confirmed: [String: String]
  /// The sessions store the scan read: another connection voids the plan.
  let store: ObjectIdentifier

  /// An estimate: sizes from the scan, before the items are measured again.
  var total: Int64 {
    worktrees.reduce(0) { $0 + ($1.size ?? 0) } + leftovers.reduce(0) { $0 + ($1.size ?? 0) }
      + (simulators?.unavailableSize ?? 0)
  }
  var count: Int { worktrees.count + leftovers.count + (simulators == nil ? 0 : 1) }
}

struct MacDiskProgress {
  var done = 0
  let total: Int
  var current: String?
  var lines: [MacDiskCleaner.Line] = []
  var finished = false
  /// Why the removal stopped before the end (a failed check, a changed connection, Parar).
  var stopped: String?
  /// The volume's free space before and after: the space really freed, snapshots and purgeable space included.
  var freeBefore: Int64?
  var freeAfter: Int64?
  /// What the removed items measured: an estimate of what they freed.
  var removed: Int64 { lines.filter(\.removed).reduce(0) { $0 + $1.bytes } }
}

/// Removes one item at a time, only after checking it again with fresh facts: worktrees through
/// `git worktree remove` (never a branch, never one with submodules), leftovers inside `$TMPDIR/opencode` only and
/// reached without links, and unavailable simulators through `simctl`. Each result goes to the log.
enum MacDiskCleaner {
  struct Line: Sendable, Identifiable {
    let id = UUID()
    let kind: String
    let path: String
    let bytes: Int64
    let removed: Bool
    let reason: String?
  }

  /// `links` and `processes` were read right before this item; `confirmed` is the state whose loss was confirmed.
  @concurrent static func remove(_ worktree: DiskCleanup.Worktree, confirmed: String?, links: [DiskCleanup.SessionLink],
    processes: MacDiskProcesses) async -> Line {
    let path = worktree.path
    func kept(_ reason: String) -> Line {
      Line(kind: "worktree", path: path, bytes: worktree.size ?? 0, removed: false, reason: reason)
    }
    let sessions = DiskCleanup.sessions(of: path, links)
    guard sessions.active == 0 else { return kept("ganhou uma sessão") }
    guard !processes.uses(path) else { return kept("um processo está usando") }
    guard let repository = worktree.repository, repository != path else { return kept("sem repositório principal") }
    var fresh = DiskCleanup.Worktree(path: path, kind: worktree.kind, repository: repository, branch: worktree.branch)
    fresh.gitLocked = worktree.gitLocked
    fresh = MacDiskProbe.facts(fresh, bases: MacDiskProbe.bases(repository))
    fresh.sessions = sessions
    switch DiskCleanup.verdict(fresh, local: true) {
    case .locked: return kept(fresh.submodules > 0 ? "tem submódulos" : "o git não confirmou o estado")
    case .confirm where !DiskCleanup.confirmed(fresh, by: confirmed):
      return kept(confirmed == nil ? "ganhou trabalho pendente desde a análise" : "mudou desde a confirmação")
    case .confirm, .free: break
    }
    // `--force` only for uncommitted or untracked files whose loss was confirmed in this exact state; commits stay
    // in the branch. Without it git refuses anything unclean.
    let force = (fresh.dirty ?? 0) > 0 ? ["--force"] : []
    let result = MacDiskProbe.run("/usr/bin/git", ["-C", repository, "worktree", "remove"] + force + [path],
      timeout: 1800, cancellable: false)
    guard result.status == 0 else {
      return kept(result.error.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first
        ?? "git worktree remove falhou")
    }
    return Line(kind: "worktree", path: path, bytes: worktree.size ?? 0, removed: true,
      reason: fresh.branch.map { "branch \($0) mantida" })
  }

  /// `git worktree prune` for the repositories that lost worktrees: drops the records of folders already gone.
  @concurrent static func prune(_ repositories: [String]) async {
    for repository in repositories { _ = MacDiskProbe.run("/usr/bin/git", ["-C", repository, "worktree", "prune"]) }
  }

  /// The item must still be the one listed, reached from `root` without links, used by no process, fully readable
  /// and unchanged for a day anywhere inside.
  @concurrent static func remove(_ leftover: DiskCleanup.Leftover, root: String, processes: MacDiskProcesses)
    async -> Line {
    let path = leftover.path
    func kept(_ reason: String) -> Line {
      Line(kind: leftover.kind.rawValue, path: path, bytes: leftover.size ?? 0, removed: false, reason: reason)
    }
    guard DiskCleanup.automatic(leftover.kind) else { return kept("só manual") }
    if let reason = MacDiskProbe.unsafe(path, root: root, identity: leftover.identity) { return kept(reason) }
    guard !processes.uses(path) else { return kept("um processo está usando") }
    guard let measure = MacDiskProbe.measure(path) else { return kept("interrompido") }
    guard measure.complete else { return kept("não deu para ler tudo") }
    if let newest = measure.newest, Date.now.timeIntervalSince(newest) < DiskCleanup.recent { return kept("mudou há pouco") }
    // The walk took time: the path is checked once more right before removal.
    if let reason = MacDiskProbe.unsafe(path, root: root, identity: leftover.identity) { return kept(reason) }
    do { try FileManager.default.removeItem(atPath: path) } catch { return kept(error.localizedDescription) }
    return Line(kind: leftover.kind.rawValue, path: path, bytes: measure.bytes, removed: true, reason: nil)
  }

  /// Only simulators Xcode marks unavailable (their runtime is gone): none of them can be running.
  @concurrent static func removeUnavailableSimulators(_ extra: MacDiskExtra) async -> Line {
    let result = MacDiskProbe.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 600, cancellable: false)
    return Line(kind: "simuladores indisponíveis", path: "\(extra.unavailable.count) aparelhos",
      bytes: extra.unavailableSize ?? 0, removed: result.status == 0,
      reason: result.status == 0 ? nil : result.error.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Appends one tab-separated line per item: date, removido/mantido, kind, path, size and reason.
  static func log(_ lines: [Line], to url: URL) {
    let date = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withInternetDateTime])
    let text = lines.map { line in
      [date, line.removed ? "removido" : "mantido", line.kind, line.path, DiskCleanup.bytes(line.bytes), line.reason ?? ""]
        .joined(separator: "\t")
    }.joined(separator: "\n") + "\n"
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(text.utf8))
      try? handle.close()
    } else {
      try? Data(text.utf8).write(to: url)
    }
  }
}
