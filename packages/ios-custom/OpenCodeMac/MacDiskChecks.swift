#if DEBUG
import AppKit
import OpenCodeKit

/// `-OpenCodeMacFixture contexto -OpenCodeMacDiskFixture <folder> -OpenCodeMacDiskChecks <captures>`, prepared by
/// `script/test-mac-disk.sh`: opens Espaço em disco over the fixture's fake repositories, worktrees and temporary
/// folder, checks how each row is classified and what is marked, previews, cleans, and checks that exactly the
/// expected items left the disk while the rest and every branch stayed. Prints `MacDiskChecks …`, saves captures and
/// exits 0 or 1. It refuses to run without the fixture folder, and the app stays in the background.
@MainActor enum MacDiskChecks {
  static let folder = MacFixture.value("-OpenCodeMacDiskChecks")
  /// `-OpenCodeMacFixture contexto -OpenCodeMacDiskSurvey <captures>`: this Mac's real folders, read only (`clean`
  /// returns at once), against the in-memory server, whose `/tmp` makes it remote: every worktree stays locked.
  /// Prints how long each phase took and what was found, saves a capture and exits.
  static let survey = MacFixture.value("-OpenCodeMacDiskSurvey")

  static func run(runtime: MacWindowRuntime, store: SessionStore) async {
    if let survey { return await measure(runtime: runtime, folder: survey) }
    guard let folder else { return }
    let disk = runtime.app.disk
    guard disk.roots.fixture else {
      print("MacDiskChecks FAIL sem -OpenCodeMacDiskFixture")
      exit(1)
    }
    var failures: [String] = []
    func check(_ ok: Bool, _ label: String) {
      print("MacDiskChecks \(ok ? "ok" : "FAIL") \(label)")
      if !ok { failures.append(label) }
    }
    let root = disk.roots.userTemp
    let temp = disk.roots.temp
    let worktreesFolder = root + "/Worktrees"
    let fm = FileManager.default
    runtime.window?.setFrame(NSRect(x: -4000, y: 40, width: 1500, height: 940), display: true)
    try? await Task.sleep(for: .seconds(2))

    // Subprocesses: a full stderr does not block, a stuck tool is stopped (finding 11); a vanished subfolder keeps
    // its real path (finding 10).
    let flood = await MacDiskProbe.off { MacDiskProbe.run("/bin/sh", ["-c", "head -c 2000000 /dev/zero >&2; echo fim"]) }
    check(flood.output.trimmingCharacters(in: .whitespacesAndNewlines) == "fim" && flood.error.utf8.count == 2_000_000,
      "stderr cheio não trava (\(flood.error.utf8.count) bytes)")
    let started = Date.now
    let stuck = await MacDiskProbe.off { MacDiskProbe.run("/bin/sleep", ["30"], timeout: 1) }
    check(stuck.status != 0 && Date.now.timeIntervalSince(started) < 5, "processo travado é encerrado (\(stuck.error))")
    check(MacDiskProbe.real(worktreesFolder.replacingOccurrences(of: "/private/var/", with: "/var/") + "/alpha-parada/x/y")
      == worktreesFolder + "/alpha-parada/x/y", "subpasta que não existe resolve pelo ancestral")

    runtime.diskVisible = true
    guard await wait(60, { disk.scannedAt != nil && !disk.scanning }) else {
      print("MacDiskChecks FAIL a análise não terminou")
      exit(1)
    }
    try? await Task.sleep(for: .seconds(1))

    let now = Date.now
    for worktree in disk.worktrees {
      let status = DiskCleanup.status(worktree, local: disk.local, now: now)
      print("MacDiskChecks linha \(worktree.name): \(status.title)\(status.detail.map { " / \($0)" } ?? "") · "
        + "\(disk.verdict(worktree)) · \(disk.selected.contains(worktree.path) ? "marcada" : "desmarcada") · "
        + (worktree.size.map(DiskCleanup.bytes) ?? "—"))
    }
    func row(_ name: String) -> DiskCleanup.Worktree? { disk.worktrees.first { $0.name == name } }
    func expect(_ name: String, _ verdict: DiskCleanup.Verdict, marked: Bool, _ text: String) {
      guard let worktree = row(name) else { return check(false, "\(name) listada") }
      let status = DiskCleanup.status(worktree, local: disk.local, now: now)
      check(disk.verdict(worktree) == verdict && disk.selected.contains(worktree.path) == marked
        && (status.title + " " + (status.detail ?? "")).contains(text), "\(name): \(verdict), \(marked ? "marcada" : "desmarcada"), “\(text)”")
    }
    expect("alpha-limpa", .free, marked: true, "parada há")
    expect("alpha-integrada", .free, marked: true, "branch já integrada")
    expect("alpha-arquivada", .free, marked: true, "Só sessões arquivadas")
    expect("alpha-so-node-modules", .free, marked: true, "Sem sessão")
    expect("alpha-recente", .free, marked: false, "mudou")
    expect("alpha-suja", .confirm, marked: false, "arquivos não commitados")
    expect("alpha-local", .confirm, marked: false, "commit não enviado")
    expect("alpha-ignorado", .confirm, marked: false, "1 item ignorado (.env)")
    expect("alpha-submodulo", .locked, marked: false, "Tem submódulos")
    expect("alpha-com-sessao", .locked, marked: false, "trabalhando")
    expect("alpha-parada", .locked, marked: false, "sem atividade")
    expect("alpha-em-uso", .locked, marked: false, "Em uso")
    expect("clone-solto", .locked, marked: false, "Clone independente")
    expect("pasta-comum", .locked, marked: false, "Não é do git")
    check(!disk.worktrees.contains { $0.path == root + "/repos/alpha" }, "o checkout principal não aparece")

    func leftover(_ name: String) -> DiskCleanup.Leftover? { disk.leftovers.first { $0.path == temp + "/" + name } }
    let removable = Set(disk.leftovers.filter { DiskCleanup.removable($0, now: now) }.map(\.path))
    let expected = Set(["dd-velho", "trabalho/derived", "Velho.app", "velho.log", "teste.xcresult",
      "editado.xcresult", "job/test.xcresult"].map { temp + "/" + $0 })
    check(removable == expected, "sobras removíveis: \(removable.map { $0.replacingOccurrences(of: temp + "/", with: "") }.sorted())")
    check(leftover("fonte-com-build")?.kind == .other, "checkout com Build/ e info.plist é código, não build")
    check(!disk.leftovers.contains { $0.path.hasPrefix(temp + "/trabalho/fonte") }, "checkout aninhado nem é listado")
    check(leftover("falso-dd")?.kind == .other, "Build/ e info.plist sem WorkspacePath não é DerivedData")
    check(leftover("Copia App.app")?.inUse == true, "app usado por caminho com espaço fica")
    check(leftover("Build Pasta")?.inUse == true, "-derivedDataPath com espaço fica")
    check(leftover("dd-em-uso")?.inUse == true, "build usado por um processo fica")
    check(leftover("captura.png")?.kind == .capture, "captura só aparece")
    check(leftover("backup.db")?.kind == .other, "backup fica em outros")
    let double = leftover("duplo")?.size ?? 0
    check(double > 1_000_000 && double < 1_500_000, "hardlink contado uma vez (\(DiskCleanup.bytes(double)))")
    let builds = disk.leftovers.filter { $0.kind == .build }
    check(DiskCleanup.summary(.build, builds, now: now).contains("de worktrees que já não existem"),
      "builds: \(DiskCleanup.summary(.build, builds, now: now))")

    guard let window = runtime.window else { return finish(failures) }
    MacCapture.shot(window, theme: .selected, to: folder + "/disco-tela.png")

    // Marking a worktree with pending work asks first; cancelling leaves it unmarked.
    if let dirty = row("alpha-suja") {
      disk.toggle(dirty)
      try? await Task.sleep(for: .seconds(1))
      check(disk.confirming?.worktree.path == dirty.path && !disk.selected.contains(dirty.path), "pendente pede confirmação")
      if let sheet = window.attachedSheet { MacCapture.shot(sheet, theme: .selected, to: folder + "/disco-confirmacao.png") }
      disk.confirming = nil
      try? await Task.sleep(for: .milliseconds(600))
      check(!disk.selected.contains(dirty.path), "cancelar deixa desmarcada")
      // A confirmation ends with the preview it was given for (finding 7).
      disk.toggle(dirty)
      disk.confirm()
      check(disk.selected.contains(dirty.path), "confirmada fica marcada")
      disk.preview()
      try? await Task.sleep(for: .milliseconds(600))
      disk.cancelPreview()
      try? await Task.sleep(for: .milliseconds(600))
      check(!disk.selected.contains(dirty.path) && disk.confirmed[dirty.path] == nil, "cancelar a prévia desfaz a confirmação")
      disk.toggle(dirty)
      check(disk.confirming?.worktree.path == dirty.path, "marcar de novo pede confirmação de novo")
      disk.confirming = nil
    }
    for name in ["alpha-com-sessao", "alpha-submodulo"] {
      guard let locked = row(name) else { continue }
      disk.toggle(locked)
      check(!disk.selected.contains(locked.path) && disk.confirming == nil, "\(name) nunca marca")
    }
    // Confirmed with one unsent commit; it gains an uncommitted file before its turn (finding 7).
    if let local = row("alpha-local") {
      disk.toggle(local)
      disk.confirm()
      check(disk.selected.contains(local.path), "alpha-local confirmada")
    }

    // A stale plan that missed the submodule (finding 3): the cleaner reads git again and refuses.
    if var stale = row("alpha-submodulo"), let processes = await MacDiskProbe.off({ MacDiskProbe.processes() }) {
      stale.submodules = 0
      let line = await MacDiskCleaner.remove(stale, confirmed: stale.fingerprint, links: [], processes: processes)
      let log = MacDiskProbe.run("/usr/bin/git", ["-C", worktreesFolder + "/alpha-submodulo/lib", "log", "--oneline"]).output
      check(!line.removed && line.reason == "tem submódulos" && log.contains("trabalho-local-do-submodulo"),
        "submódulo com commit local fica (\(line.reason ?? ""))")
    }

    // The world changes during the cleanup, one item at a time (findings 4, 6, 7 and 8).
    var watcher: Process?
    MacDiskFixture.beforeRemoval = { path in
      switch path {
      case worktreesFolder + "/alpha-limpa":
        let url = URL(fileURLWithPath: root + "/sessions.json")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "[]"
        text = String(text.dropLast(2)) + #",{"id":"ses_nova","directory":"\#(path)","archived":false,"running":true}]"# + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
      case worktreesFolder + "/alpha-local":
        try? "depois\n".write(toFile: path + "/depois.txt", atomically: true, encoding: .utf8)
      case temp + "/velho.log":
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", path]
        tail.standardOutput = FileHandle.nullDevice
        try? tail.run()
        watcher = tail
        try? await Task.sleep(for: .milliseconds(300))
      case temp + "/editado.xcresult":
        if let handle = FileHandle(forWritingAtPath: path + "/blob") {
          _ = try? handle.seekToEnd()
          try? handle.write(contentsOf: Data("mudou".utf8))
          try? handle.close()
        }
      case temp + "/job/test.xcresult":
        try? fm.moveItem(atPath: temp + "/job", toPath: temp + "/job-antes")
        try? fm.createSymbolicLink(atPath: temp + "/job", withDestinationPath: root + "/fora/job")
      default: break
      }
    }

    disk.preview()
    try? await Task.sleep(for: .seconds(1))
    guard let plan = disk.plan else {
      check(false, "prévia aberta")
      return finish(failures)
    }
    check(Set(plan.worktrees.map(\.name)) == ["alpha-limpa", "alpha-integrada", "alpha-arquivada", "alpha-local",
      "alpha-so-node-modules"], "prévia: worktrees \(plan.worktrees.map(\.name).sorted())")
    check(Set(plan.leftovers.map(\.path)) == expected, "prévia: \(plan.leftovers.count) sobras")
    if let preview = window.attachedSheet?.attachedSheet {
      MacCapture.shot(preview, theme: .selected, to: folder + "/disco-previa.png")
    }
    await disk.clean(plan, sessions: store)
    MacDiskFixture.beforeRemoval = nil
    watcher?.terminate()
    try? await Task.sleep(for: .seconds(1))
    if let preview = window.attachedSheet?.attachedSheet {
      MacCapture.shot(preview, theme: .selected, to: folder + "/disco-resultado.png")
    }
    let lines = disk.progress?.lines ?? []
    for line in lines where !line.removed { print("MacDiskChecks ficou \(line.path): \(line.reason ?? "")") }
    func reason(_ path: String) -> String? { lines.first { $0.path == path && !$0.removed }?.reason }
    check(lines.count == 12 && lines.filter(\.removed).count == 7, "7 de 12 itens removidos")
    check(reason(worktreesFolder + "/alpha-limpa") == "ganhou uma sessão", "sessão nova no meio da limpeza protege")
    check(reason(worktreesFolder + "/alpha-local") == "mudou desde a confirmação"
      && fm.fileExists(atPath: worktreesFolder + "/alpha-local/depois.txt"), "mudança depois da confirmação protege")
    check(reason(temp + "/velho.log") == "um processo está usando", "processo novo no meio da limpeza protege")
    check(reason(temp + "/editado.xcresult") == "mudou há pouco", "arquivo alterado por dentro protege")
    check(reason(temp + "/job/test.xcresult") == "o caminho passa por um link"
      && fm.fileExists(atPath: root + "/fora/job/test.xcresult/Info.plist")
      && fm.fileExists(atPath: temp + "/job-antes/test.xcresult/Info.plist"), "link no caminho não apaga fora da pasta")
    if let before = disk.progress?.freeBefore, let after = disk.progress?.freeAfter {
      print("MacDiskChecks espaço livre \(DiskCleanup.bytes(before)) → \(DiskCleanup.bytes(after))")
    }

    for name in ["alpha-integrada", "alpha-arquivada", "alpha-so-node-modules"] {
      check(!fm.fileExists(atPath: worktreesFolder + "/" + name), "\(name) removida")
    }
    for name in ["alpha-limpa", "alpha-local", "alpha-recente", "alpha-suja", "alpha-ignorado", "alpha-submodulo",
      "alpha-com-sessao", "alpha-parada", "alpha-em-uso", "clone-solto", "pasta-comum"] {
      check(fm.fileExists(atPath: worktreesFolder + "/" + name), "\(name) ficou")
    }
    check(fm.fileExists(atPath: worktreesFolder + "/alpha-ignorado/.env"), ".env ficou")
    for name in ["dd-velho", "trabalho/derived", "Velho.app", "teste.xcresult"] {
      check(!fm.fileExists(atPath: temp + "/" + name), "\(name) removido")
    }
    for name in ["dd-recente", "dd-em-uso", "novo.log", "velho.log", "captura.png", "backup.db", "trabalho/notas.txt",
      "uploads", "fonte-com-build/Sources/novo.swift", "trabalho/fonte/Sources/novo.swift", "falso-dd", "Copia App.app",
      "Build Pasta", "editado.xcresult"] {
      check(fm.fileExists(atPath: temp + "/" + name), "\(name) ficou")
    }
    let branches = MacDiskProbe.run("/usr/bin/git", ["-C", root + "/repos/alpha", "branch", "--list"]).output
    check(["feat/integrada", "feat/arquivada", "feat/so-node-modules"].allSatisfy(branches.contains), "branches mantidas")
    let listed = MacDiskProbe.run("/usr/bin/git", ["-C", root + "/repos/alpha", "worktree", "list"]).output
    check(!listed.contains("alpha-integrada"), "git worktree list sem as removidas")
    let log = (try? String(contentsOfFile: disk.roots.log.path, encoding: .utf8)) ?? ""
    check(log.components(separatedBy: "\tremovido\t").count - 1 == 7, "registro com 7 remoções")

    disk.finish()
    _ = await wait(60) { !disk.scanning && disk.scannedAt != nil }
    try? await Task.sleep(for: .seconds(1))
    check(!disk.worktrees.contains { $0.name == "alpha-integrada" }, "a tela se atualiza depois de limpar")
    MacCapture.shot(window, theme: .selected, to: folder + "/disco-depois.png")

    // The server stops answering for sessions (finding 5): nothing is removed and the run says why.
    if let recent = row("alpha-recente") {
      disk.toggle(recent)
      disk.preview(only: recent)
      MacDiskFixture.sessionsFail = true
      if let plan = disk.plan { await disk.clean(plan, sessions: store) }
      MacDiskFixture.sessionsFail = false
      check(disk.progress?.stopped?.contains("sessões") == true && fm.fileExists(atPath: recent.path),
        "sem resposta do servidor nada sai (\(disk.progress?.stopped ?? "—"))")
      disk.finish()
    }
    finish(failures)
  }

  private static func measure(runtime: MacWindowRuntime, folder: String) async {
    let disk = runtime.app.disk
    guard MacLaunch.fixture, !disk.roots.fixture else {
      print("MacDiskChecks survey FAIL: só com -OpenCodeMacFixture e sem -OpenCodeMacDiskFixture")
      exit(1)
    }
    runtime.window?.setFrame(NSRect(x: -4000, y: 40, width: 1500, height: 940), display: true)
    try? await Task.sleep(for: .seconds(2))
    let start = Date.now
    func elapsed() -> String { String(format: "%.1f s", Date.now.timeIntervalSince(start)) }
    runtime.diskVisible = true
    _ = await wait(120) { !disk.worktrees.isEmpty && !disk.leftovers.isEmpty }
    print("MacDiskChecks survey descoberta \(elapsed()): \(disk.worktrees.count) worktrees, \(disk.leftovers.count) sobras, local=\(disk.local)")
    _ = await wait(300) { disk.worktrees.allSatisfy { $0.known || $0.gitLocked || $0.repository == nil } }
    print("MacDiskChecks survey git \(elapsed())")
    let first = await wait(300) { disk.worktrees.allSatisfy { !disk.measuring.contains($0.path) } }
    print("MacDiskChecks survey tamanhos das worktrees \(elapsed()) \(first ? "" : "(incompleto)")")
    if let window = runtime.window { MacCapture.shot(window, theme: .selected, to: folder + "/disco-real-worktrees.png") }
    let done = await wait(1500) { disk.scannedAt != nil && !disk.scanning }
    print("MacDiskChecks survey tudo \(elapsed()) \(done ? "" : "(incompleto)")")
    let now = Date.now
    let kinds = [DiskCleanup.Worktree.Kind.worktree, .clone, .folder].map { kind in "\(kind): \(disk.worktrees.filter { $0.kind == kind }.count)" }
    print("MacDiskChecks survey worktrees \(kinds.joined(separator: ", ")) · total \(DiskCleanup.bytes(disk.worktrees.reduce(0) { $0 + ($1.size ?? 0) }))"
      + " · pendentes \(disk.worktrees.filter(\.pending).count) · integradas \(disk.worktrees.filter(\.integrated).count)"
      + " · em uso \(disk.worktrees.filter(\.inUse).count) · marcadas \(disk.selected.count)")
    for kind in DiskCleanup.Leftover.Kind.allCases {
      let items = disk.leftovers.filter { $0.kind == kind }
      let removable = items.filter { DiskCleanup.removable($0, now: now) }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
      print("MacDiskChecks survey \(kind): \(DiskCleanup.bytes(items.reduce(0) { $0 + ($1.size ?? 0) })) · "
        + DiskCleanup.summary(kind, items, now: now) + " · removível \(DiskCleanup.bytes(removable))")
    }
    for extra in disk.extras {
      print("MacDiskChecks survey \(extra.kind): \(extra.size.map(DiskCleanup.bytes) ?? "—") · \(extra.detail)"
        + (extra.unavailableSize.map { " · indisponíveis \(DiskCleanup.bytes($0))" } ?? ""))
    }
    print("MacDiskChecks survey dá para liberar \(DiskCleanup.bytes(disk.freeable))")
    if let window = runtime.window { MacCapture.shot(window, theme: .selected, to: folder + "/disco-real.png") }
    fflush(stdout)
    exit(0)
  }

  private static func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(seconds)
    while Date.now < end {
      if done() { return true }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return done()
  }

  private static func finish(_ failures: [String]) {
    print(failures.isEmpty ? "MacDiskChecks ok" : "MacDiskChecks FAIL \(failures.count)")
    fflush(stdout)
    exit(failures.isEmpty ? 0 : 1)
  }
}
#endif
