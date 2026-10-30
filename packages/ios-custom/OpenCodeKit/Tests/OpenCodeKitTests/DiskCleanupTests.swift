import Foundation
import Testing
@testable import OpenCodeKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func worktree(dirty: Int? = 0, unpushed: Int? = 0, ignored: [String]? = [], submodules: Int = 0,
  changed: TimeInterval = 3 * 86_400, sessions: DiskCleanup.Worktree.Sessions = .init(), inUse: Bool = false)
  -> DiskCleanup.Worktree {
  var worktree = DiskCleanup.Worktree(path: "/w/feat", kind: .worktree, repository: "/repo", branch: "feat")
  worktree.dirty = dirty
  worktree.unpushed = unpushed
  worktree.ignored = ignored
  worktree.submodules = submodules
  worktree.fingerprint = "head\n\(unpushed ?? 0)\n\(dirty ?? 0)"
  worktree.lastChange = now.addingTimeInterval(-changed)
  worktree.sessions = sessions
  worktree.inUse = inUse
  return worktree
}

@Test func onlyCleanWorktreesWithoutLiveSessionsAreMarked() {
  #expect(DiskCleanup.preselected(worktree(), local: true, now: now))
  // A live session (running or not), a process, a remote server or submodules never let it be marked.
  #expect(DiskCleanup.verdict(worktree(sessions: .init(active: 1)), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(sessions: .init(active: 2, running: true)), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(inUse: true), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(), local: false) == .locked)
  #expect(DiskCleanup.verdict(worktree(dirty: 1, submodules: 1), local: true) == .locked)
  #expect(DiskCleanup.status(worktree(submodules: 1), local: true, now: now).title == "Tem submódulos")
  // Pending work, ignored files nothing recreates included, needs a confirmation and is never marked by default.
  #expect(DiskCleanup.verdict(worktree(dirty: 3), local: true) == .confirm)
  #expect(DiskCleanup.verdict(worktree(unpushed: 2), local: true) == .confirm)
  #expect(DiskCleanup.verdict(worktree(ignored: [".env"]), local: true) == .confirm)
  #expect(DiskCleanup.status(worktree(ignored: [".env"]), local: true, now: now).title == "1 item ignorado (.env)")
  #expect(!DiskCleanup.preselected(worktree(dirty: 3), local: true, now: now))
  // Not checked by git yet (ignored files included), recent, clones and plain folders.
  #expect(DiskCleanup.verdict(worktree(dirty: nil), local: true) == .locked)
  #expect(DiskCleanup.verdict(worktree(ignored: nil), local: true) == .locked)
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

@Test func aConfirmationHoldsOnlyForTheStateItWasGivenFor() {
  let confirmed = worktree(unpushed: 1)
  #expect(DiskCleanup.confirmed(confirmed, by: confirmed.fingerprint))
  #expect(!DiskCleanup.confirmed(worktree(dirty: 1, unpushed: 1), by: confirmed.fingerprint))
  #expect(!DiskCleanup.confirmed(confirmed, by: nil))
}

@Test func ignoredFilesCountUnlessABuildRecreatesThem() {
  let status = DiskCleanup.porcelain(" M a.swift\0?? novo.txt\0R  novo-nome.swift\0velho.swift\0!! .env\0!! node_modules/\0!! data/local.db\0!! app/.build/\0")
  #expect(status.changed == [" M a.swift", "?? novo.txt", "R  novo-nome.swift"])
  #expect(status.ignored == [".env", "node_modules/", "data/local.db", "app/.build/"])
  #expect(status.ignored.filter { !DiskCleanup.regenerable($0) } == [".env", "data/local.db"])
  #expect(DiskCleanup.regenerable("packages/web/node_modules/x/.env"))
  #expect(DiskCleanup.regenerable("core/node_modules"))
  #expect(DiskCleanup.regenerable("Abacato.Core.Api/obj/") && DiskCleanup.regenerable(".husky/_/"))
  #expect(!DiskCleanup.regenerable("build"))
  // Secrets, local settings, virtualenvs and artifacts are work: they stay protected.
  #expect([".venv/", "server/secrets", "android/local.properties", ".agent-artifacts/"]
    .allSatisfy { !DiskCleanup.regenerable($0) })
}

@Test func leftoversInUseRecentUnreadOrManualStay() {
  var build = DiskCleanup.Leftover(path: "/t/dd", kind: .build)
  build.identity = .init(device: 1, inode: 2)
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
  var unread = build
  unread.complete = false
  #expect(!DiskCleanup.removable(unread, now: now))
  var backup = DiskCleanup.Leftover(path: "/t/backup.db", kind: .other)
  backup.size = 10
  backup.newest = build.newest
  #expect(!DiskCleanup.removable(backup, now: now))
  #expect(DiskCleanup.kind(name: "x.xcresult", directory: true, derivedData: false, bundle: true) == .tests)
  #expect(DiskCleanup.kind(name: "x.xcresult", directory: true, derivedData: false) == .other)
  #expect(DiskCleanup.kind(name: "run.log", directory: false, derivedData: false) == .log)
  #expect(DiskCleanup.kind(name: "shot.png", directory: false, derivedData: false) == .capture)
  #expect(DiskCleanup.kind(name: "db-backup.db", directory: false, derivedData: false) == .other)
}

@Test func onlyARealDerivedDataIsABuild() {
  let derived: Set = ["Build", "Logs", "info.plist", "ModuleCache.noindex"]
  #expect(DiskCleanup.derivedData(entries: derived, workspacePath: "/w/App.xcodeproj", checkout: false))
  // A checkout with a Build folder and an info.plist is source, whatever the plist says.
  #expect(!DiskCleanup.derivedData(entries: derived.union([".git"]), workspacePath: "/w/App.xcodeproj", checkout: true))
  #expect(!DiskCleanup.derivedData(entries: derived, workspacePath: nil, checkout: false))
  #expect(!DiskCleanup.derivedData(entries: ["Build", "info.plist", "Sources"], workspacePath: "/w/App.xcodeproj",
    checkout: false))
}

@Test func processesAndTheServerAreMatchedByPath() {
  let processes = DiskCleanup.ProcessUse(
    commands: [
      ["/usr/bin/xcodebuild", "xcodebuild", "-derivedDataPath", "/var/folders/pm/x/T/opencode/Build Folder", "build"],
      ["/private/var/folders/pm/x/T/opencode/Copied App.app/Contents/MacOS/Copied App", "--flag"],
      ["/bin/tool", "--output=/var/folders/pm/x/T/opencode/out dir/file"],
    ],
    directories: ["/w/feat/packages", "/w"])
  #expect(processes.uses("/private/var/folders/pm/x/T/opencode/Build Folder"))
  #expect(processes.uses("/var/folders/pm/x/T/opencode/Copied App.app"))
  #expect(processes.uses("/var/folders/pm/x/T/opencode/out dir"))
  #expect(!processes.uses("/private/var/folders/pm/x/T/opencode/Build"))
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
