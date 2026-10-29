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

/// What the processes of this Mac use: each one's arguments, as the kernel keeps them (also read for running
/// emulators), and working folder.
struct MacDiskProcesses: Sendable {
  let commands: [[String]]
  let use: DiskCleanup.ProcessUse

  init(commands: [[String]], directories: [String]) {
    self.commands = commands
    use = DiskCleanup.ProcessUse(commands: commands, directories: directories)
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

  /// Every process this user can read, from the kernel: its arguments with their real boundaries
  /// (`KERN_PROCARGS2`, so a path with spaces stays one argument) and its working folder (`PROC_PIDVNODEPATHINFO`).
  /// nil when the process list itself cannot be read.
  static func processes() -> MacDiskProcesses? {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 256)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return nil }
    var size = 0
    var maximum: Int32 = 0
    var name = [CTL_KERN, KERN_ARGMAX]
    size = MemoryLayout<Int32>.size
    guard sysctl(&name, 2, &maximum, &size, nil, 0) == 0, maximum > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(maximum))
    var commands: [[String]] = []
    var directories: [String] = []
    for pid in pids.prefix(Int(count)) where pid > 0 {
      if let command = arguments(pid, buffer: &buffer) { commands.append(command) }
      var info = proc_vnodepathinfo()
      let expected = Int32(MemoryLayout<proc_vnodepathinfo>.size)
      if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, expected) == expected {
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !path.isEmpty { directories.append(path) }
      }
    }
    return MacDiskProcesses(commands: commands, directories: directories)
  }

  /// `KERN_PROCARGS2`: argc, the executable path, padding, then argc NUL-terminated arguments.
  private static func arguments(_ pid: pid_t, buffer: inout [UInt8]) -> [String]? {
    var name = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = buffer.count
    guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    let bytes = buffer[MemoryLayout<Int32>.size..<size]
    var index = bytes.startIndex
    func next() -> String? {
      guard index < bytes.endIndex else { return nil }
      let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
      defer { index = min(end + 1, bytes.endIndex) }
      return String(decoding: bytes[index..<end], as: UTF8.self)
    }
    guard let executable = next() else { return nil }
    // Only the executable path is followed by padding; an empty argument is a single NUL.
    while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
    var strings = [executable]
    for _ in 0..<argc {
      guard let argument = next() else { break }
      strings.append(argument)
    }
    return strings
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

  /// Uncommitted files, ignored files nothing regenerates, initialized submodules, commits on no remote, whether
  /// HEAD is already in the base branch, and the last change git knows. Read-only: `--no-optional-locks` keeps
  /// `status` from rewriting the index. Any git failure locks the row.
  static func facts(_ worktree: DiskCleanup.Worktree, bases: [String]) -> DiskCleanup.Worktree {
    var worktree = worktree
    guard worktree.kind == .worktree, worktree.repository != nil else { return worktree }
    let path = worktree.path
    let status = run("/usr/bin/git", ["-C", path, "--no-optional-locks", "status", "--porcelain=v1", "-z",
      "--untracked-files=normal", "--ignored=traditional"], timeout: 180)
    let unpushed = run("/usr/bin/git", ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"])
    let head = run("/usr/bin/git", ["-C", path, "rev-parse", "HEAD"])
    // Submodules carry their own git data and commits inside the worktree.
    let submodules = isFile(path + "/.gitmodules")
      ? run("/usr/bin/git", ["-C", path, "--no-optional-locks", "submodule", "status", "--recursive"]) : nil
    guard status.status == 0, unpushed.status == 0, head.status == 0, let count = Int(unpushed.output.trimmed),
      submodules.map({ $0.status == 0 }) ?? true else {
      worktree.gitLocked = true
      return worktree
    }
    let entries = DiskCleanup.porcelain(status.output)
    let ignored = entries.ignored.filter { !DiskCleanup.regenerable($0) }.sorted()
    worktree.dirty = entries.changed.count
    worktree.unpushed = count
    worktree.ignored = ignored
    worktree.submodules = (submodules?.output.split(separator: "\n") ?? []).filter { !$0.hasPrefix("-") }.count
    worktree.fingerprint = ([head.output.trimmed, "\(count)"] + entries.changed.sorted() + ignored)
      .joined(separator: "\n")
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
  /// without what was classified inside it. A checkout (`.git`, a file or a folder) is never classified nor entered:
  /// whatever it holds is someone's source.
  static func leftovers(root: String) -> (items: [DiskCleanup.Leftover], skips: [String: [String]]) {
    let fm = FileManager.default
    var items: [DiskCleanup.Leftover] = []
    var skips: [String: [String]] = [:]
    func checkout(_ path: String) -> Bool { exists(path + "/.git") }
    func classified(_ path: String, depth: Int) -> DiskCleanup.Leftover? {
      guard !isLink(path) else { return nil }
      let name = URL(fileURLWithPath: path).lastPathComponent
      let directory = isDirectory(path)
      guard !directory || !checkout(path) else { return nil }
      let entries = directory ? Set((try? fm.contentsOfDirectory(atPath: path)) ?? []) : []
      let workspace = entries.contains("info.plist")
        ? NSDictionary(contentsOfFile: path + "/info.plist")?["WorkspacePath"] as? String : nil
      let derived = directory && isDirectory(path + "/Build")
        && DiskCleanup.derivedData(entries: entries, workspacePath: workspace, checkout: false)
      let bundle = directory && (isFile(path + "/Info.plist") || isFile(path + "/Contents/Info.plist"))
      let kind = DiskCleanup.kind(name: name, directory: directory, derivedData: derived, bundle: bundle)
      guard depth == 1 || [.build, .tests, .app].contains(kind) else { return nil }
      guard kind != .other else { return nil }
      var item = DiskCleanup.Leftover(path: path, kind: kind)
      item.identity = identity(path)
      if derived, let workspace {
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
        guard isDirectory(path), !isLink(path), !checkout(path) else { return [] }
        if let item = classified(path, depth: depth) { return [item] }
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
      let inside = isDirectory(path) && !isLink(path) && !checkout(path) ? nested(in: path, depth: 2) : []
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
          return processes.commands.contains { command in
            command.contains { $0.contains("qemu-system") } && zip(command, command.dropFirst()).contains { $0 == "-avd" && $1 == avd }
          }
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

  struct Measure: Sendable {
    let bytes: Int64
    let newest: Date?
    /// Every entry was read: a folder that cannot be listed or an entry that cannot be examined makes it false.
    let complete: Bool
  }

  /// Allocated bytes (a file with several hard links counted once) and the newest change under `path`, without
  /// following links or leaving the volume; `skip` folders are left out. Stops early (nil) when the task is
  /// cancelled.
  static func measure(_ path: String, skip: [String] = []) -> Measure? {
    let skip = Set(skip)
    var bytes: Int64 = 0
    var newest: Double = 0
    var complete = true
    var linked: Set<DiskCleanup.FileIdentity> = []
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
      if info == FTS_DNR || info == FTS_ERR || info == FTS_NS { complete = false }
      if info == FTS_D, !skip.isEmpty, skip.contains(String(cString: entry.pointee.fts_path)) {
        _ = fts_set(fts, entry, FTS_SKIP)
        continue
      }
      guard info != FTS_NS, let stat = entry.pointee.fts_statp else { continue }
      if stat.pointee.st_nlink > 1, info != FTS_D,
        !linked.insert(DiskCleanup.FileIdentity(device: Int64(stat.pointee.st_dev), inode: stat.pointee.st_ino)).inserted {
        continue
      }
      bytes += Int64(stat.pointee.st_blocks) * 512
      newest = max(newest, Double(stat.pointee.st_mtimespec.tv_sec))
    }
    return Measure(bytes: bytes, newest: newest > 0 ? Date(timeIntervalSince1970: newest) : nil, complete: complete)
  }

  /// Why removing `path` would not touch exactly the item listed inside `root`: a folder on the way (or the item)
  /// is a link, or the item is not the one listed (device and inode). nil when it is safe.
  static func unsafe(_ path: String, root: String, identity expected: DiskCleanup.FileIdentity?) -> String? {
    guard let expected, DiskCleanup.contains(root, path), path != root else { return "fora da pasta temporária" }
    guard real(root) == root else { return "a pasta temporária mudou de lugar" }
    let relative = path.dropFirst(root.count + 1).split(separator: "/")
    var current = root
    for component in relative {
      guard component != "..", component != "." else { return "caminho inválido" }
      current += "/" + component
      var info = stat()
      guard lstat(current, &info) == 0 else { return "não está mais lá" }
      if info.st_mode & S_IFMT == S_IFLNK { return "o caminho passa por um link" }
    }
    guard identity(path) == expected else { return "não é mais o mesmo item" }
    return nil
  }

  static func identity(_ path: String) -> DiskCleanup.FileIdentity? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return DiskCleanup.FileIdentity(device: Int64(info.st_dev), inode: info.st_ino)
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

  /// Runs a tool and waits, reading stdout and stderr together. Past `timeout` seconds, or when the calling task is
  /// cancelled and `cancellable`, the tool is stopped (SIGTERM, then SIGKILL) and reaped, and the result is a
  /// failure. Git runs without its fsmonitor hook, so a stuck hook cannot hold a check.
  static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 60, cancellable: Bool = true) -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_CONFIG_COUNT"] = "1"
    environment["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
    environment["GIT_CONFIG_VALUE_0"] = "false"
    environment["LC_ALL"] = "C"
    process.environment = environment
    let output = Pipe()
    let failure = Pipe()
    process.standardOutput = output
    process.standardError = failure
    process.standardInput = FileHandle.nullDevice
    let collected = Collected()
    for (pipe, error) in [(output, false), (failure, true)] {
      pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil }
        collected.append(data, error: error)
      }
    }
    defer {
      output.fileHandleForReading.readabilityHandler = nil
      failure.fileHandleForReading.readabilityHandler = nil
    }
    do { try process.run() } catch { return Output(status: -1, output: "", error: error.localizedDescription) }
    let deadline = Date.now.addingTimeInterval(timeout)
    var stopped: String?
    while process.isRunning {
      if cancellable, Task.isCancelled { stopped = "interrompido" }
      if Date.now > deadline { stopped = "demorou mais de \(Int(timeout)) s" }
      if stopped != nil { break }
      usleep(20_000)
    }
    if let stopped {
      process.terminate()
      let grace = Date.now.addingTimeInterval(2)
      while process.isRunning, Date.now < grace { usleep(20_000) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      return Output(status: -1, output: "", error: "\(URL(fileURLWithPath: tool).lastPathComponent) \(stopped)")
    }
    process.waitUntilExit()
    // Both pipes to their end; a grandchild that keeps them open is not waited for past two seconds.
    let drained = Date.now.addingTimeInterval(2)
    while !collected.ended, Date.now < drained { usleep(5_000) }
    return Output(status: process.terminationStatus, output: String(decoding: collected.output, as: UTF8.self),
      error: String(decoding: collected.error, as: UTF8.self))
  }

  private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var outEnded = false
    private var errEnded = false
    var output: Data { lock.withLock { out } }
    var error: Data { lock.withLock { err } }
    var ended: Bool { lock.withLock { outEnded && errEnded } }
    func append(_ data: Data, error: Bool) {
      lock.withLock {
        switch (data.isEmpty, error) {
        case (true, true): errEnded = true
        case (true, false): outEnded = true
        case (false, true): err.append(data)
        case (false, false): out.append(data)
        }
      }
    }
  }

  /// The real path (`/var` → `/private/var`, links resolved), so paths from git, the server and the file system
  /// compare equal. A path that no longer exists keeps its missing tail on its nearest existing folder's real path.
  static func real(_ path: String) -> String {
    var head = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    var tail: [Substring] = []
    while true {
      if let resolved = realpath(head, nil) {
        defer { free(resolved) }
        let base = String(cString: resolved)
        return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
      }
      guard let slash = head.lastIndex(of: "/"), head != "/" else { return path }
      tail.append(head[head.index(after: slash)...])
      head = slash == head.startIndex ? "/" : String(head[..<slash])
    }
  }

  /// Exists, a broken link included.
  static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
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
