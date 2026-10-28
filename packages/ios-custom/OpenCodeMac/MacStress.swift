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

  static func run(runtime: MacRuntime, openWindow: OpenWindowAction) async {
    guard enabled else { return }
    let idle = MacFixture.value("-OpenCodeMacStress").flatMap(Double.init) ?? 30
    try? await Task.sleep(for: .seconds(3))
    guard let window = mainWindow else { return finish("sem janela principal", status: 1) }
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
      }
    }
    await step("tamanho inicial") { window.setFrame(start, display: true) }
    for _ in 0..<2 {
      await step("Sessões") { toggleSidebar(window) }
      await step("Contexto") { runtime.contextVisible.toggle() }
    }
    await step("Arquivos") { runtime.showFiles() }
    await step("fechar Arquivos") { runtime.selection.files = nil }
    await step("LLM proxy") { openWindow(id: MacProxyWindow.id) }
    await step("fechar LLM proxy") { NSApp.windows.first { $0.title == "LLM proxy" }?.close() }
    await step("parada \(Int(idle)) s", wait: idle) { window.makeKeyAndOrderFront(nil) }
    finish("ok", status: 0)
  }

  /// Launched from a shell while the screen is locked, SwiftUI opens no window until the app is activated;
  /// the stress run opens one through File ▸ New Window.
  static func openWindowIfNeeded() {
    guard enabled || MacCapture.folder != nil || ScrollFixtures.mode != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard !NSApp.windows.contains(where: \.isVisible) else { return }
      func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
      guard let item = items(NSApp.mainMenu).first(where: { $0.keyEquivalent == "n" }), let menu = item.menu else { return }
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
