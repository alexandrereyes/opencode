import Foundation
import Testing
@testable import OpenCodeKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func worktree(dirty: Int? = 0, unpushed: Int? = 0, changed: TimeInterval = 3 * 86_400,
  sessions: DiskCleanup.Worktree.Sessions = .init(), inUse: Bool = false) -> DiskCleanup.Worktree {
  var worktree = DiskCleanup.Worktree(path: "/w/feat", kind: .worktree, repository: "/repo", branch: "feat")
  worktree.dirty = dirty
  worktree.unpushed = unpushed
  worktree.lastChange = now.addingTimeInterval(-changed)
  worktree.sessions = sessions
  worktree.inUse = inUse
  return worktree
}

@Test func onlyCleanWorktreesWithoutLiveSessionsAreMarked() {
  #expect(DiskCleanup.preselected(worktree(), local: true, now: now))
  // A live session (running or not), a process or a remote server never lets it be marked.
  #expect(DiskCleanup.verdict(worktree(sessions: .init(active: 1)), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(sessions: .init(active: 2, running: true)), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(inUse: true), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(), local: false) == .locked)
  // Pending work is selectable only after a confirmation, and never marked by default.
  #expect(DiskCleanup.verdict(worktree(dirty: 3), local: true) == .confirm)
  #expect(DiskCleanup.verdict(worktree(unpushed: 2), local: true) == .confirm)
  #expect(!DiskCleanup.preselected(worktree(dirty: 3), local: true, now: now))
  // Not checked by git yet, recent, clones and plain folders.
  #expect(DiskCleanup.verdict(worktree(dirty: nil), local: true) == .locked)
  #expect(!DiskCleanup.preselected(worktree(changed: 3600), local: true, now: now))
  #expect(DiskCleanup.verdict(DiskCleanup.Worktree(path: "/w/clone", kind: .clone), local: true) == .locked)
  #expect(DiskCleanup.verdict(DiskCleanup.Worktree(path: "/w/x", kind: .folder), local: true) == .locked)
}

@Test func archivedSessionsDoNotHoldAWorktree() {
  let links = [
    DiskCleanup.SessionLink(id: "a", directory: "/w/feat/packages/app", root: true, archived: true, running: false),
    DiskCleanup.SessionLink(id: "b", directory: "/w/feature", root: true, archived: false, running: true),
  ]
  let sessions = DiskCleanup.sessions(of: "/w/feat", links)
  #expect(sessions == .init(active: 0, running: false, archived: 1))
  let archived = worktree(sessions: sessions)
  #expect(DiskCleanup.preselected(archived, local: true, now: now))
  #expect(DiskCleanup.status(archived, local: true, now: now).title == "Só sessões arquivadas")
  let live = DiskCleanup.sessions(of: "/w/feat", links + [
    DiskCleanup.SessionLink(id: "c", directory: "/w/feat", root: true, archived: false, running: true),
  ])
  #expect(DiskCleanup.status(worktree(sessions: live), local: true, now: now)
    == .init(title: "1 sessão", detail: "trabalhando", tone: .working, locked: true))
}

@Test func leftoversInUseRecentOrManualStay() {
  var build = DiskCleanup.Leftover(path: "/t/dd", kind: .build)
  #expect(!DiskCleanup.removable(build, now: now))
  build.size = 10
  build.newest = now.addingTimeInterval(-2 * 86_400)
  #expect(DiskCleanup.removable(build, now: now))
  var used = build
  used.inUse = true
  #expect(!DiskCleanup.removable(used, now: now))
  var recent = build
  recent.newest = now.addingTimeInterval(-600)
  #expect(!DiskCleanup.removable(recent, now: now))
  var backup = DiskCleanup.Leftover(path: "/t/backup.db", kind: .other)
  backup.size = 10
  backup.newest = build.newest
  #expect(!DiskCleanup.removable(backup, now: now))
  #expect(DiskCleanup.kind(name: "x.xcresult", directory: true, derivedData: false) == .tests)
  #expect(DiskCleanup.kind(name: "run.log", directory: false, derivedData: false) == .log)
  #expect(DiskCleanup.kind(name: "shot.png", directory: false, derivedData: false) == .capture)
  #expect(DiskCleanup.kind(name: "db-backup.db", directory: false, derivedData: false) == .other)
}

@Test func processesAndTheServerAreMatchedByPath() {
  let processes = DiskCleanup.ProcessUse(
    arguments: ["xcodebuild -derivedDataPath /var/folders/pm/x/T/opencode/dd-ios build",
      "/private/var/folders/pm/x/T/opencode/Copia.app/Contents/MacOS/Copia --flag"],
    directories: ["/w/feat/packages", "/w"])
  #expect(processes.uses("/private/var/folders/pm/x/T/opencode/dd-ios"))
  #expect(processes.uses("/var/folders/pm/x/T/opencode/Copia.app"))
  #expect(!processes.uses("/private/var/folders/pm/x/T/opencode/dd-ios-2"))
  #expect(processes.uses("/w/feat"))
  #expect(!processes.uses("/w/feature"))
  #expect(DiskCleanup.local(serverTemp: "/private/var/folders/pm/x/T/opencode", userTemp: "/var/folders/pm/x/T"))
  #expect(!DiskCleanup.local(serverTemp: "/tmp/opencode", userTemp: "/var/folders/pm/x/T"))
  #expect(!DiskCleanup.local(serverTemp: nil, userTemp: "/var/folders/pm/x/T"))
  #expect(DiskCleanup.level(free: 90, total: 1800) == .low)
  #expect(DiskCleanup.level(free: 80, total: 1800) == .critical)
  #expect(DiskCleanup.level(free: 620, total: 1800) == .roomy)
  #expect(DiskCleanup.bytes(90 << 30) == "90 GB")
  #expect(DiskCleanup.bytes(1_995_000_000_000) == "1,8 TB")
  #expect(DiskCleanup.bytes(15_354 << 20) == "15 GB")
}
