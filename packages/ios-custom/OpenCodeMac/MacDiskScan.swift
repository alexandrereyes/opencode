import Darwin
import Foundation
import OpenCodeKit

/// Where Espaço em disco looks and writes. A DEBUG fixture (`-OpenCodeMacDiskFixture <folder>`) moves every one of
/// them into that folder, so a check never reads or removes a real worktree or temporary folder.
struct MacDiskRoots: Sendable {
  /// `~/Worktrees`: every folder in it is listed.
  let worktrees: String
  /// `$TMPDIR/opencode`: the agents' builds, copies, logs and captures.
  let temp: String
  /// This user's temporary folder, compared with the server's to tell whether it runs on this Mac.
  let userTemp: String
  let extras: [MacDiskExtra.Kind: [String]]
  let cache: URL
  let log: URL
  /// `xcrun simctl delete unavailable` and the AVD count run only against the real folders.
  let fixture: Bool

  static let current: MacDiskRoots = {
    #if DEBUG
    if let root = MacFixture.value("-OpenCodeMacDiskFixture") { return fixture(MacDiskProbe.real(root)) }
    #endif
    let home = NSHomeDirectory()
    let userTemp = MacDiskProbe.real(NSTemporaryDirectory())
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "br.com.alexandrem.opencode.mac", isDirectory: true)
    return MacDiskRoots(worktrees: home + "/Worktrees", temp: userTemp + "/opencode", userTemp: userTemp,
      extras: [
        .simulators: [home + "/Library/Developer/CoreSimulator/Devices"],
        .emulators: [home + "/.android/avd"],
        .snapshots: [home + "/.local/share/opencode/snapshot"],
        .derivedData: [home + "/Library/Developer/Xcode/DerivedData"],
        .packages: [home + "/.bun/install/cache", home + "/.npm/_cacache"],
        .caches: [home + "/Library/Caches"],
      ],
      cache: caches.appendingPathComponent("disk-sizes.json"),
      log: URL(fileURLWithPath: home + "/Library/Logs/OpenCode/limpeza-de-disco.log"), fixture: false)
  }()

  #if DEBUG
  private static func fixture(_ root: String) -> MacDiskRoots {
    MacDiskRoots(worktrees: root + "/Worktrees", temp: root + "/tmp", userTemp: root, extras: [:],
      cache: URL(fileURLWithPath: root + "/disk-sizes.json"), log: URL(fileURLWithPath: root + "/limpeza-de-disco.log"),
      fixture: true)
  }
  #endif
}

/// A row of Sujeira dos agentes outside `$TMPDIR/opencode`: simulators, emulators, snapshots, Xcode's DerivedData
/// and caches. Only the simulators that Xcode marks unavailable are ever removed (`simctl delete unavailable`).
struct MacDiskExtra: Sendable, Equatable, Identifiable {
  enum Kind: String, Sendable, CaseIterable { case simulators, emulators, snapshots, derivedData, packages, caches }
  let kind: Kind
  let paths: [String]
  var size: Int64?
  var detail: String
  /// Unavailable simulators' folders, removed by `xcrun simctl delete unavailable`.
  var unavailable: [String] = []
  var unavailableSize: Int64?
  var id: String { kind.rawValue }

  var title: String {
    switch kind {
    case .simulators: "Simuladores iOS"
    case .emulators: "Emuladores Android"
    case .snapshots: "Snapshots do OpenCode"
    case .derivedData: "DerivedData do Xcode"
    case .packages: "Caches de pacotes (bun, npm)"
    case .caches: "Caches de apps (~/Library/Caches)"
    }
  }
}

/// What the processes of this Mac use: their arguments (also read for running emulators) and working folders.
struct MacDiskProcesses: Sendable {
  let arguments: [String]
  let use: DiskCleanup.ProcessUse

  init(arguments: [String], directories: [String]) {
    self.arguments = arguments
    use = DiskCleanup.ProcessUse(arguments: arguments, directories: directories)
  }

  func uses(_ path: String) -> Bool { use.uses(path) }
}

/// Reads git, the processes and the file system for Espaço em disco, off the main thread. Nothing here deletes;
/// removal is `MacDiskCleaner`.
enum MacDiskProbe {
  // MARK: Volume

  static func volume() -> (free: Int64, total: Int64)? {
    let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    guard let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity
    else { return nil }
    return (free, Int64(total))
  }

  // MARK: Processes

  static func processes() -> MacDiskProcesses {
    let arguments = run("/bin/ps", ["-axww", "-o", "args="]).output.split(separator: "\n").map(String.init)
    // `-b` never waits on a hung mount; `-w` drops its warnings. Every process's working folder, one `n` line each.
    let directories = run("/usr/sbin/lsof", ["-w", "-b", "-a", "-d", "cwd", "-Fn"]).output.split(separator: "\n")
      .filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    return MacDiskProcesses(arguments: arguments, directories: directories)
  }

  // MARK: Worktrees

  /// Every linked worktree of the known repositories (`git worktree list`) and every folder in `folder`, without
  /// the repositories' own checkouts.
  static func worktrees(folder: String, repositories: [String]) -> [DiskCleanup.Worktree] {
    let fm = FileManager.default
    let children = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
      .map { real(folder + "/" + $0) }.filter { isDirectory($0) }
    var mains: Set<String> = []
    var listed: [String: DiskCleanup.Worktree] = [:]
    // A worktree in `folder` names its repository too, so worktrees of a repository OpenCode never saw are found.
    let candidates = repositories.filter { isDirectory($0) }.map(real) + children.filter { isFile($0 + "/.git") }
    for candidate in candidates where listed[candidate] == nil && !mains.contains(candidate) {
      let result = run("/usr/bin/git", ["-C", candidate, "worktree", "list", "--porcelain"])
      guard result.status == 0 else { continue }
      let entries = DiskCleanup.worktreeList(result.output)
      guard let main = entries.first, !main.bare || entries.count > 1 else { continue }
      mains.insert(real(main.path))
      for entry in entries.dropFirst() where !entry.prunable && isDirectory(entry.path) {
        var worktree = DiskCleanup.Worktree(path: real(entry.path), kind: .worktree, repository: real(main.path),
          branch: entry.branch)
        worktree.gitLocked = entry.locked
        listed[worktree.path] = worktree
      }
    }
    // A repository's own checkout in `folder` is listed as a clone, never as a worktree to remove.
    for child in children where listed[child] == nil {
      if isDirectory(child + "/.git") || mains.contains(child) {
        listed[child] = DiskCleanup.Worktree(path: child, kind: .clone)
      } else if isFile(child + "/.git") {
        // Its repository is gone or unreadable: nothing can remove it safely from here.
        listed[child] = DiskCleanup.Worktree(path: child, kind: .worktree)
      } else {
        listed[child] = DiskCleanup.Worktree(path: child, kind: .folder)
      }
    }
    return listed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Uncommitted files, commits on no remote, whether HEAD is already in the base branch, and the last change git
  /// knows. Read-only: `--no-optional-locks` keeps `status` from rewriting the index.
  static func facts(_ worktree: DiskCleanup.Worktree, bases: [String]) -> DiskCleanup.Worktree {
    var worktree = worktree
    guard worktree.kind == .worktree, worktree.repository != nil else { return worktree }
    let path = worktree.path
    let status = run("/usr/bin/git", ["-C", path, "--no-optional-locks", "status", "--porcelain", "--untracked-files=normal"])
    let unpushed = run("/usr/bin/git", ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"])
    guard status.status == 0, unpushed.status == 0, let count = Int(unpushed.output.trimmed) else {
      worktree.gitLocked = true
      return worktree
    }
    worktree.dirty = status.output.split(separator: "\n").count
    worktree.unpushed = count
    worktree.integrated = bases.contains { base in
      run("/usr/bin/git", ["-C", path, "merge-base", "--is-ancestor", "HEAD", base]).status == 0
    }
    let committed = Double(run("/usr/bin/git", ["-C", path, "log", "-1", "--format=%ct"]).output.trimmed)
      .map { Date(timeIntervalSince1970: $0) }
    let gitDirectory = run("/usr/bin/git", ["-C", path, "rev-parse", "--absolute-git-dir"]).output.trimmed
    let touched = ([path] + (gitDirectory.isEmpty ? [] : [gitDirectory + "/index", gitDirectory + "/logs/HEAD"]))
      .compactMap(modified)
    worktree.lastChange = ([committed].compactMap { $0 } + touched).max()
    return worktree
  }

  /// The main checkout's branch and `origin/HEAD`: a worktree whose HEAD is in one of them has nothing of its own.
  static func bases(_ repository: String) -> [String] {
    let branch = run("/usr/bin/git", ["-C", repository, "symbolic-ref", "--quiet", "--short", "HEAD"]).output.trimmed
    let origin = run("/usr/bin/git", ["-C", repository, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
      .output.trimmed
    return [branch, origin].filter { !$0.isEmpty }
  }

  // MARK: Leftovers

  /// The temporary folder's items: Xcode builds (a DerivedData, found up to three levels down), test results and
  /// copied apps (two levels), logs and captures (top level); the rest of each top-level item is "other", measured
  /// without what was classified inside it.
  static func leftovers(root: String) -> (items: [DiskCleanup.Leftover], skips: [String: [String]]) {
    let fm = FileManager.default
    var items: [DiskCleanup.Leftover] = []
    var skips: [String: [String]] = [:]
    func classified(_ path: String, depth: Int) -> DiskCleanup.Leftover? {
      let name = URL(fileURLWithPath: path).lastPathComponent
      let directory = isDirectory(path)
      let derived = directory && isDirectory(path + "/Build") && isFile(path + "/info.plist")
      let kind = DiskCleanup.kind(name: name, directory: directory, derivedData: derived)
      guard depth == 1 || [.build, .tests, .app].contains(kind) else { return nil }
      guard kind != .other else { return nil }
      var item = DiskCleanup.Leftover(path: path, kind: kind)
      if derived, let plist = NSDictionary(contentsOfFile: path + "/info.plist"),
        let workspace = plist["WorkspacePath"] as? String {
        item.origin = workspace
        item.originExists = fm.fileExists(atPath: workspace)
      }
      return item
    }
    func nested(in folder: String, depth: Int) -> [DiskCleanup.Leftover] {
      guard depth <= 3 else { return [] }
      let names = ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
        .filter { !$0.hasPrefix(".") && $0 != "node_modules" }
      return names.flatMap { name -> [DiskCleanup.Leftover] in
        let path = folder + "/" + name
        guard isDirectory(path), !isLink(path) else { return [] }
        if let item = classified(path, depth: depth) { return [item] }
        // A checkout copied into the folder is someone's source, not a build.
        guard !fm.fileExists(atPath: path + "/.git") else { return [] }
        return nested(in: path, depth: depth + 1)
      }
    }
    let names = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0 != ".DS_Store" }
    for name in names {
      let path = root + "/" + name
      if let item = classified(path, depth: 1) {
        items.append(item)
        continue
      }
      let inside = isDirectory(path) && !isLink(path) && !fm.fileExists(atPath: path + "/.git")
        ? nested(in: path, depth: 2) : []
      items.append(contentsOf: inside)
      items.append(DiskCleanup.Leftover(path: path, kind: .other))
      if !inside.isEmpty { skips[path] = inside.map(\.path) }
    }
    return (items, skips)
  }

  // MARK: Extras

  /// Each row's folders and the counts in its detail; the sizes come from `measure`.
  static func extras(_ roots: MacDiskRoots, processes: MacDiskProcesses) -> [MacDiskExtra] {
    MacDiskExtra.Kind.allCases.compactMap { kind in
      guard let paths = roots.extras[kind] else { return nil }
      let existing = paths.filter { isDirectory($0) }
      switch kind {
      case .simulators:
        let devices = roots.fixture ? [] : simulators()
        let booted = devices.filter { $0.state == "Booted" }.count
        let unavailable = devices.filter { !$0.available }
        var parts = ["\(devices.count) aparelhos"]
        if booted > 0 { parts.append("\(booted) ligados") }
        parts.append(unavailable.isEmpty ? "nenhum indisponível" : "\(unavailable.count) indisponíveis")
        return MacDiskExtra(kind: kind, paths: existing, detail: parts.joined(separator: " · "),
          unavailable: unavailable.map(\.folder).filter { isDirectory($0) })
      case .emulators:
        let names = existing.flatMap { folder in
          ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".avd") }
        }
        let running = names.filter { name in
          let avd = String(name.dropLast(4))
          return processes.arguments.contains { $0.contains("qemu-system") && $0.contains("-avd " + avd) }
        }.count
        return MacDiskExtra(kind: kind, paths: existing,
          detail: "\(names.count) AVDs" + (running > 0 ? " · \(running) ligados" : "") + " · só manual")
      case .snapshots, .derivedData, .packages, .caches:
        return MacDiskExtra(kind: kind, paths: existing, detail: "só manual")
      }
    }
  }

  private struct Simulator { let folder: String; let state: String; let available: Bool }

  private static func simulators() -> [Simulator] {
    struct List: Decodable {
      let devices: [String: [Device]]
      struct Device: Decodable { let udid: String; let state: String?; let isAvailable: Bool?; let dataPath: String? }
    }
    let output = run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"]).output
    guard let list = try? JSONDecoder().decode(List.self, from: Data(output.utf8)) else { return [] }
    let root = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/"
    return list.devices.values.flatMap { $0 }.map {
      Simulator(folder: root + $0.udid, state: $0.state ?? "", available: $0.isAvailable ?? true)
    }
  }

  // MARK: Sizes

  struct Measure: Sendable { let bytes: Int64; let newest: Date? }

  /// Allocated bytes and the newest change under `path`, without following links or leaving the volume; `skip`
  /// folders are left out. Stops early (nil) when the task is cancelled.
  static func measure(_ path: String, skip: [String] = []) -> Measure? {
    let skip = Set(skip)
    var bytes: Int64 = 0
    var newest: Double = 0
    var visited = 0
    guard let pointer = strdup(path) else { return nil }
    defer { free(pointer) }
    var paths: [UnsafeMutablePointer<CChar>?] = [pointer, nil]
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
      visited += 1
      if visited % 4096 == 0, Task.isCancelled { return nil }
      let info = Int32(entry.pointee.fts_info)
      if info == FTS_DP { continue }
      if info == FTS_D, !skip.isEmpty, skip.contains(String(cString: entry.pointee.fts_path)) {
        _ = fts_set(fts, entry, FTS_SKIP)
        continue
      }
      guard let stat = entry.pointee.fts_statp else { continue }
      bytes += Int64(stat.pointee.st_blocks) * 512
      newest = max(newest, Double(stat.pointee.st_mtimespec.tv_sec))
    }
    return Measure(bytes: bytes, newest: newest > 0 ? Date(timeIntervalSince1970: newest) : nil)
  }

  /// Runs `work` over `inputs`, `width` at a time off the main thread, handing the results over in batches.
  @concurrent static func parallel<Input: Sendable, Result: Sendable>(_ inputs: [Input], width: Int,
    work: @escaping @Sendable (Input) -> Result, deliver: @escaping @Sendable ([Result]) async -> Void) async {
    await withTaskGroup(of: Result.self) { group in
      var pending = inputs.makeIterator()
      for _ in 0..<width {
        guard let input = pending.next() else { break }
        group.addTask { work(input) }
      }
      var batch: [Result] = []
      var flushed = ContinuousClock.now
      for await result in group {
        batch.append(result)
        if !Task.isCancelled, let input = pending.next() { group.addTask { work(input) } }
        if ContinuousClock.now - flushed > .milliseconds(250) {
          await deliver(batch)
          batch = []
          flushed = .now
        }
      }
      if !batch.isEmpty { await deliver(batch) }
    }
  }

  @concurrent static func off<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result { work() }

  // MARK: Helpers

  struct Output: Sendable { let status: Int32; let output: String; let error: String }

  /// Runs a tool and waits. Output is read before stderr: the tools here write little to stderr.
  static func run(_ tool: String, _ arguments: [String]) -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["LC_ALL"] = "C"
    process.environment = environment
    let output = Pipe()
    let failure = Pipe()
    process.standardOutput = output
    process.standardError = failure
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return Output(status: -1, output: "", error: error.localizedDescription) }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = failure.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
      error: String(decoding: message, as: UTF8.self))
  }

  /// The real path (`/var` → `/private/var`), so paths from git, the server and the file system compare equal.
  static func real(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else {
      return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func modified(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  static func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
  }

  static func isFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
  }

  private static func isLink(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
