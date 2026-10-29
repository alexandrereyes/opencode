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
    runtime.window?.setFrame(NSRect(x: -4000, y: 40, width: 1500, height: 940), display: true)
    try? await Task.sleep(for: .seconds(2))
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
    expect("alpha-recente", .free, marked: false, "mudou")
    expect("alpha-suja", .confirm, marked: false, "arquivos não commitados")
    expect("alpha-local", .confirm, marked: false, "commit não enviado")
    expect("alpha-com-sessao", .locked, marked: false, "trabalhando")
    expect("alpha-parada", .locked, marked: false, "sem atividade")
    expect("alpha-em-uso", .locked, marked: false, "Em uso")
    expect("clone-solto", .locked, marked: false, "Clone independente")
    expect("pasta-comum", .locked, marked: false, "Não é do git")
    check(!disk.worktrees.contains { $0.path == root + "/repos/alpha" }, "o checkout principal não aparece")

    let temp = disk.roots.temp
    let removable = Set(disk.leftovers.filter { DiskCleanup.removable($0, now: now) }.map(\.path))
    let expected: Set = [temp + "/dd-velho", temp + "/trabalho/derived", temp + "/Velho.app", temp + "/velho.log",
      temp + "/teste.xcresult"]
    check(removable == expected, "sobras removíveis: \(removable.map { $0.replacingOccurrences(of: temp + "/", with: "") }.sorted())")
    check(disk.leftovers.first { $0.path == temp + "/dd-em-uso" }?.inUse == true, "build usado por um processo fica")
    check(disk.leftovers.first { $0.path == temp + "/captura.png" }?.kind == .capture, "captura só aparece")
    check(disk.leftovers.first { $0.path == temp + "/backup.db" }?.kind == .other, "backup fica em outros")
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
    }
    if let locked = row("alpha-com-sessao") {
      disk.toggle(locked)
      check(!disk.selected.contains(locked.path), "com sessão nunca marca")
    }

    disk.preview()
    try? await Task.sleep(for: .seconds(1))
    guard let plan = disk.plan else {
      check(false, "prévia aberta")
      return finish(failures)
    }
    check(Set(plan.worktrees.map(\.name)) == ["alpha-limpa", "alpha-integrada", "alpha-arquivada"],
      "prévia: worktrees \(plan.worktrees.map(\.name).sorted())")
    check(Set(plan.leftovers.map(\.path)) == expected, "prévia: \(plan.leftovers.count) sobras")
    if let preview = window.attachedSheet?.attachedSheet {
      MacCapture.shot(preview, theme: .selected, to: folder + "/disco-previa.png")
    }
    await disk.clean(plan, sessions: store)
    try? await Task.sleep(for: .seconds(1))
    if let preview = window.attachedSheet?.attachedSheet {
      MacCapture.shot(preview, theme: .selected, to: folder + "/disco-resultado.png")
    }
    let lines = disk.progress?.lines ?? []
    for line in lines where !line.removed { print("MacDiskChecks ficou \(line.path): \(line.reason ?? "")") }
    check(lines.count == 8 && lines.allSatisfy(\.removed), "8 itens removidos")

    let fm = FileManager.default
    for name in ["alpha-limpa", "alpha-integrada", "alpha-arquivada"] {
      check(!fm.fileExists(atPath: root + "/Worktrees/" + name), "\(name) removida")
    }
    for name in ["alpha-recente", "alpha-suja", "alpha-local", "alpha-com-sessao", "alpha-parada", "alpha-em-uso",
      "clone-solto", "pasta-comum"] {
      check(fm.fileExists(atPath: root + "/Worktrees/" + name), "\(name) ficou")
    }
    for path in expected { check(!fm.fileExists(atPath: path), "\(path.replacingOccurrences(of: temp + "/", with: "")) removido") }
    for name in ["dd-recente", "dd-em-uso", "novo.log", "captura.png", "backup.db", "trabalho/notas.txt", "uploads"] {
      check(fm.fileExists(atPath: temp + "/" + name), "\(name) ficou")
    }
    let branches = MacDiskProbe.run("/usr/bin/git", ["-C", root + "/repos/alpha", "branch", "--list"]).output
    check(["feat/limpa", "feat/integrada", "feat/arquivada"].allSatisfy(branches.contains), "branches mantidas")
    let listed = MacDiskProbe.run("/usr/bin/git", ["-C", root + "/repos/alpha", "worktree", "list"]).output
    check(!listed.contains("alpha-limpa"), "git worktree list sem as removidas")
    let log = (try? String(contentsOfFile: disk.roots.log.path, encoding: .utf8)) ?? ""
    check(log.components(separatedBy: "\tremovido\t").count - 1 == 8, "registro com 8 remoções")

    disk.finish()
    _ = await wait(60) { !disk.scanning && disk.scannedAt != nil }
    try? await Task.sleep(for: .seconds(1))
    check(!disk.worktrees.contains { $0.name == "alpha-limpa" }, "a tela se atualiza depois de limpar")
    MacCapture.shot(window, theme: .selected, to: folder + "/disco-depois.png")
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
