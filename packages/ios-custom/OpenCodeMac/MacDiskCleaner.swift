import Foundation
import OpenCodeKit

/// What Limpar removes, as approved in the preview. Every item is checked again right before it goes.
struct MacDiskPlan: Identifiable {
  let id = UUID()
  let worktrees: [DiskCleanup.Worktree]
  let leftovers: [DiskCleanup.Leftover]
  /// The unavailable simulators (`xcrun simctl delete unavailable`), when chosen.
  let simulators: MacDiskExtra?
  /// Worktrees with pending work whose loss was confirmed one by one.
  let confirmed: Set<String>

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
  var freed: Int64 { lines.filter(\.removed).reduce(0) { $0 + $1.bytes } }
}

/// Removes, one item at a time and only after checking it again: worktrees through `git worktree remove` (never a
/// branch), leftovers inside `$TMPDIR/opencode` only, and unavailable simulators through `simctl`. Each result goes
/// to the log.
enum MacDiskCleaner {
  struct Line: Sendable, Identifiable {
    let id = UUID()
    let kind: String
    let path: String
    let bytes: Int64
    let removed: Bool
    let reason: String?
  }

  @concurrent static func remove(_ worktree: DiskCleanup.Worktree, confirmed: Bool, links: [DiskCleanup.SessionLink],
    processes: MacDiskProcesses, local: Bool) async -> Line {
    let path = worktree.path
    func kept(_ reason: String) -> Line {
      Line(kind: "worktree", path: path, bytes: worktree.size ?? 0, removed: false, reason: reason)
    }
    guard local else { return kept("o servidor não está neste Mac") }
    let sessions = DiskCleanup.sessions(of: path, links)
    guard sessions.active == 0 else { return kept("ganhou uma sessão") }
    guard !processes.uses(path) else { return kept("um processo está usando") }
    guard let repository = worktree.repository, repository != path else { return kept("sem repositório principal") }
    var fresh = DiskCleanup.Worktree(path: path, kind: worktree.kind, repository: repository, branch: worktree.branch)
    fresh.gitLocked = worktree.gitLocked
    fresh = MacDiskProbe.facts(fresh, bases: MacDiskProbe.bases(repository))
    fresh.sessions = sessions
    switch DiskCleanup.verdict(fresh, local: true) {
    case .locked: return kept("o git não confirmou o estado")
    case .confirm where !confirmed: return kept("ganhou alterações desde a análise")
    case .confirm, .free: break
    }
    // `--force` only for uncommitted or untracked files, whose loss was confirmed; commits stay in the branch.
    let force = (fresh.dirty ?? 0) > 0 ? ["--force"] : []
    let result = MacDiskProbe.run("/usr/bin/git", ["-C", repository, "worktree", "remove"] + force + [path])
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

  @concurrent static func remove(_ leftover: DiskCleanup.Leftover, root: String, processes: MacDiskProcesses)
    async -> Line {
    let path = leftover.path
    func kept(_ reason: String) -> Line {
      Line(kind: leftover.kind.rawValue, path: path, bytes: leftover.size ?? 0, removed: false, reason: reason)
    }
    guard DiskCleanup.automatic(leftover.kind), path != root, DiskCleanup.contains(root, path)
    else { return kept("fora da pasta temporária dos agentes") }
    guard !processes.uses(path) else { return kept("um processo está usando") }
    // A build that started since the measurement writes its log folder first.
    let touched = [path, path + "/Logs/Build", path + "/Build/Products"].compactMap(MacDiskProbe.modified).max()
    if let touched, Date.now.timeIntervalSince(touched) < DiskCleanup.recent { return kept("mudou há pouco") }
    do { try FileManager.default.removeItem(atPath: path) } catch { return kept(error.localizedDescription) }
    return Line(kind: leftover.kind.rawValue, path: path, bytes: leftover.size ?? 0, removed: true, reason: nil)
  }

  /// Only simulators Xcode marks unavailable (their runtime is gone): none of them can be running.
  @concurrent static func removeUnavailableSimulators(_ extra: MacDiskExtra) async -> Line {
    let result = MacDiskProbe.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])
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
