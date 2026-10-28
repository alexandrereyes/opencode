#if DEBUG
import AppKit
import SwiftUI

/// A layout stress run of the main window (`-OpenCodeMacStress [idle seconds]`), against the AppKit constraint
/// loop that once closed the app on launch: it walks the window through the sizes it can take on every screen,
/// collapses and reopens Sessões and Contexto, opens and closes Arquivos and the LLM proxy window, then stays
/// idle. It prints `MacStress ok` and exits 0; a layout loop kills the process with an exception, and a
/// minimum width wider than a screen fails it. `script/test-mac-window.sh` runs it.
@MainActor enum MacStress {
  static let enabled = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacStress")

  private static var started = false
  static func run(runtime: MacWindowRuntime, openWindow: OpenWindowAction) async {
    guard enabled, !started else { return }
    started = true
    let idle = MacFixture.value("-OpenCodeMacStress").flatMap(Double.init) ?? 30
    try? await Task.sleep(for: .seconds(3))
    guard let window = mainWindow else { return finish("sem janela principal", status: 1) }
    // The search's suggestion panel hides while the app is not active (`hidesOnDeactivate`); launched from a shell
    // while someone works in another app, it would never show. Captures activate the app the same way.
    print("MacStress app ativo no início: \(NSApp.isActive)")
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    if let error = await MacChoicesChecks.run(runtime) { return finish(error, status: 1) }
    await step("Nova sessão e paleta") { runtime.newSession() }
    if let error = await MacChoicesChecks.newSession(runtime) { return finish(error, status: 1) }
    await step("fechar Nova sessão e paleta") { runtime.newSessionRequest = nil }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacChoicesOnly") { return finish("escolhas ok", status: 0) }
    guard let secondID = runtime.store?.rows.first(where: { $0.id != runtime.selection.sessionID })?.id else {
      return finish("sem segunda sessão", status: 1)
    }
    let target = MacWindowTarget(sessionID: secondID)
    await step("segunda janela") { openWindow(id: "main", value: target) }
    guard let second = runtime.app.windows[target.id], let secondWindow = second.window,
      second.selection.sessionID == secondID, secondWindow !== window,
      second.store === runtime.store else { return finish("janelas não independentes", status: 1) }
    let original = runtime.state
    await step("estado independente") {
      second.contextVisible = false
      second.contextWidth = 640
      second.selection.files = MacSelection.Files(folder: "/tmp")
      second.selection.childID = "ses_mac_c1"
      second.columns = .detailOnly
    }
    guard runtime.state == original, runtime.memory(secondID) !== second.memory(secondID) else {
      return finish("estado vazou entre janelas", status: 1)
    }
    second.selection.childID = nil
    second.selection.files = nil
    second.columns = .all
    print("MacStress duas janelas independentes ok · \(runtime.selection.sessionID ?? "-") / \(secondID)")
    if let folder = MacCapture.folder {
      MacCapture.shot(window, theme: .selected, to: folder + "/janelas-1.png")
      MacCapture.shot(secondWindow, theme: .selected, to: folder + "/janelas-2.png")
    }
    let start = window.frame
    for screen in NSScreen.screens {
      let area = screen.visibleFrame
      let sizes = [NSSize(width: 0, height: 0), NSSize(width: 1100, height: 700), NSSize(width: 1300, height: 820),
        NSSize(width: 1500, height: 940), area.size, NSSize(width: 1200, height: area.height),
        NSSize(width: area.width, height: 640)]
      for size in sizes {
        let width = min(max(size.width, window.minSize.width), area.width)
        let height = min(max(size.height, window.minSize.height), area.height)
        await step("\(screen.localizedName) \(Int(width))×\(Int(height))") {
          window.setFrame(NSRect(x: area.minX, y: area.minY, width: width, height: height), display: true)
        }
        if window.minSize.width > area.width {
          return finish("mínimo \(Int(window.minSize.width)) pt maior que \(screen.localizedName)", status: 1)
        }
        if let error = await MacSearchChecks.layout(runtime) { return finish(error + state(window), status: 1) }
      }
    }
    for context in [false, true] {
      for sidebar in [false, true] {
        await step("busca com colunas recolhidas") {
          runtime.contextVisible = context
          runtime.columns = sidebar ? .all : .detailOnly
        }
        for width in [window.minSize.width, window.screen?.visibleFrame.width ?? 1600] {
          await step("busca mínimo/máximo") {
            window.setFrame(NSRect(x: start.minX, y: start.minY, width: width, height: start.height), display: true)
          }
          if let error = await MacSearchChecks.layout(runtime) { return finish(error + state(window), status: 1) }
        }
      }
    }
    // The old 760-pt limit and well past it: the window's 60% (and the chat's minimum) bound what shows.
    for width in [400.0, 760.0, 1_400.0] {
      await step("busca com Contexto redimensionado") { runtime.contextWidth = width }
      if let error = await MacSearchChecks.layout(runtime) { return finish(error + state(window), status: 1) }
    }
    runtime.contextWidth = original.contextWidth
    await step("tamanho inicial") { window.setFrame(start, display: true) }
    for _ in 0..<2 {
      await step("Sessões") { toggleSidebar(window) }
      await step("Contexto") { runtime.contextVisible.toggle() }
    }
    await step("Arquivos") { runtime.showFiles() }
    await step("fechar Arquivos") { runtime.selection.files = nil }
    await step("LLM proxy") { openWindow(id: MacProxyWindow.id) }
    await step("fechar LLM proxy") { NSApp.windows.first { $0.title == "LLM proxy" }?.close() }
    await step("Nova sessão") { runtime.newSession() }
    await step("fechar Nova sessão") { runtime.newSessionRequest = nil }
    if let error = await MacSearchChecks.run(runtime, other: second) { return finish(error, status: 1) }
    await step("seleção") { if let id = runtime.selection.sessionID { runtime.sessionSelection.start(id) } }
    await step("fim da seleção") { runtime.sessionSelection.clear() }
    await step("recurso") { openWindow(id: "resource", value: "res_iphone") }
    await step("fechar recurso") { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("resource") == true }?.close() }
    await step("parada \(Int(idle)) s", wait: idle) { window.makeKeyAndOrderFront(nil) }
    await step("fechar segunda janela") { secondWindow.close() }
    guard runtime.app.windows[target.id] == nil, runtime.selection == original.selection else {
      return finish("fechar janela alterou a outra", status: 1)
    }
    finish("ok", status: 0)
  }

  /// Launched from a shell while the screen is locked, SwiftUI opens no window until the app is activated;
  /// the stress run and the captures open one through Arquivo ▸ Nova janela.
  static func openWindowIfNeeded() {
    guard enabled || MacCapture.folder != nil || ScrollFixtures.mode != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard !NSApp.windows.contains(where: \.isVisible) else { return }
      func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
      guard let item = items(NSApp.mainMenu).first(where: { $0.title == "Nova janela" }), let menu = item.menu else { return }
      menu.performActionForItem(at: menu.index(of: item))
    }
  }

  /// ⌃⌘S without the key window a locked screen denies: the split view controller of the window's sidebar.
  private static func toggleSidebar(_ window: NSWindow) {
    func splits(_ view: NSView) -> [NSSplitView] { ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits) }
    let controller = ((window.contentView?.superview).map(splits) ?? []).lazy.compactMap { $0.delegate as? NSSplitViewController }
      .first { $0.splitViewItems.contains { $0.behavior == .sidebar } }
    controller?.toggleSidebar(nil)
  }

  /// Whether the app and the window were in front when a check failed: the search panel hides otherwise.
  private static func state(_ window: NSWindow) -> String {
    " · app ativo \(NSApp.isActive), janela principal \(window.isKeyWindow)"
  }

  private static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.title != "LLM proxy" }
  }

  private static func step(_ name: String, wait: Double = 1.5, _ action: () -> Void) async {
    action()
    try? await Task.sleep(for: .seconds(wait))
    let size = mainWindow.map { "janela \(Int($0.frame.width))×\(Int($0.frame.height)), mínimo \(Int($0.minSize.width))" } ?? ""
    print("MacStress " + name + " · " + size)
    fflush(stdout)
  }

  private static func finish(_ message: String, status: Int32) {
    print("MacStress " + message)
    fflush(stdout)
    exit(status)
  }
}
#endif
