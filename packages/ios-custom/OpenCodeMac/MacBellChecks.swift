#if DEBUG
import AppKit
import OpenCodeKit
import Synchronization

/// `-OpenCodeMacFixture contexto -OpenCodeMacFixtureBell <s>`: two answers wait unread at launch and another arrives
/// `s` seconds later (`MacFixture`). With the composer focused, the arrival must open the bell's panel without taking
/// the keyboard, close it again, and opening that line must clear it. Prints `MacBellChecks …` and exits 0 or 1.
/// The app stays in the background (the bell treats it as in use), so the run never takes the Mac's keyboard.
@MainActor enum MacBellChecks {
  nonisolated static let arrival = MacFixture.value("-OpenCodeMacFixtureBell").flatMap(Double.init)
  private nonisolated static let views = Mutex<Set<String>>([])
  private static var started = false

  nonisolated static func view(_ id: String) { views.withLock { _ = $0.insert(id) } }
  nonisolated static func viewed(_ id: String) -> Bool { views.withLock { $0.contains(id) } }

  /// Unstructured, so a title bar rebuilt by the selection does not cancel it.
  static func start(store: SessionStore, runtime: MacWindowRuntime, panel: MacBellPanel) {
    guard arrival != nil, !started else { return }
    started = true
    Task { await run(store: store, runtime: runtime, panel: panel) }
  }

  private static func run(store: SessionStore, runtime: MacWindowRuntime, panel: MacBellPanel) async {
    guard let arrival else { return }
    let start = Date.now
    // The fixture has no event stream: reread the list as the server's updates would.
    let polling = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        await store.reload()
      }
    }
    defer { polling.cancel() }
    func at(_ seconds: Double) async {
      try? await Task.sleep(for: .seconds(max(0, seconds - Date.now.timeIntervalSince(start))))
    }
    var failures: [String] = []
    func check(_ ok: Bool, _ label: String) {
      print("MacBellChecks \(ok ? "ok" : "FAIL") \(label)")
      if !ok { failures.append(label) }
    }

    // Off-screen, so the run never sits under the Mac user's pointer.
    runtime.window?.setFrame(NSRect(x: -4000, y: 40, width: 1500, height: 940), display: true)
    await at(arrival - 3)
    runtime.focusComposer()
    await at(arrival - 1)
    let responder = runtime.window?.firstResponder
    report("antes", store: store, runtime: runtime, panel: panel)
    check(responder is NSTextView, "compositor com o teclado antes")
    check(!panel.visible, "painel fechado antes")

    await at(arrival + 2)
    report("chegada", store: store, runtime: runtime, panel: panel)
    // `-OpenCodeMacBellShot <png>`: the window with the panel open.
    if let path = MacFixture.value("-OpenCodeMacBellShot"), let window = runtime.window {
      MacCapture.shot(window, theme: .selected, to: path)
    }
    let inbox = runtime.app.alertInbox
    check(inbox.fresh == ["ses_mac_android"], "só a nova destacada")
    check(panel.visible, "painel aberto sozinho")
    check(!panel.window.canBecomeKey && !panel.window.isKeyWindow && NSApp.keyWindow !== panel.window,
      "painel não vira key")
    check(runtime.window?.firstResponder === responder, "compositor continua com o teclado")
    check(count(store) == dots(store), "sino igual a Precisa de você")

    await at(arrival + 8)
    check(!panel.visible, "painel fechou sozinho")
    let before = count(store)
    if let item = inbox.unread(store.rows, store: store).first(where: { $0.id == "ses_mac_android" }) {
      inbox.open(item, store: store, runtime: runtime)
    }
    await at(arrival + 12)
    report("aberta", store: store, runtime: runtime, panel: panel)
    check(!inbox.unread(store.rows, store: store).contains { $0.id == "ses_mac_android" }, "abrir zera a linha")
    check(count(store) == before - 1 && count(store) == dots(store), "sino igual a Precisa de você depois")
    // Read while open, it keeps its place in "Precisa de você" without counting.
    let attention = SessionSections.group(store.filtered, now: .now, held: store.attentionHold)
      .first { $0.kind == .attention }?.rows.map(\.id) ?? []
    check(attention.contains("ses_mac_android"), "aberta fica em Precisa de você")
    if let path = MacFixture.value("-OpenCodeMacBellShot"), let window = runtime.window {
      MacCapture.shot(window, theme: .selected, to: path.replacingOccurrences(of: ".png", with: "-aberta.png"))
    }
    check(inbox.fresh.isEmpty, "sem destaque depois de ler")
    exit(failures.isEmpty ? 0 : 1)
  }

  private static func count(_ store: SessionStore) -> Int {
    MacRuntime.shared.alertInbox.unread(store.rows, store: store).count
  }

  /// The count of "Precisa de você" under Todas.
  private static func dots(_ store: SessionStore) -> Int { SessionAttention.count(store.rows) }

  private static func report(_ moment: String, store: SessionStore, runtime: MacWindowRuntime, panel: MacBellPanel) {
    let responder = runtime.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    print("MacBellChecks \(moment): sino=\(count(store)) precisa=\(dots(store)) painel=\(panel.visible) "
      + "responder=\(responder) fresh=\(runtime.app.alertInbox.fresh.sorted())")
  }
}
#endif
