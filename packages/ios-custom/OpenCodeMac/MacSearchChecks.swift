#if DEBUG
import AppKit
import OpenCodeKit

/// `-OpenCodeMacSearchTrace`: for each key the window receives, the time from the key event to the end of the
/// main-thread pass that first renders the results or shows the panel after it (`abrir` for ⌘K, `filtrar` for the
/// others). It also logs the selection, the chosen result and the session the window then shows.
@MainActor enum MacSearchTrace {
  static let enabled = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacSearchTrace")
  private static var monitor: Any?
  private static var key: (label: String, at: TimeInterval)?

  static func start() {
    guard enabled, monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let open = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "k"
      key = (open ? "abrir" : "filtrar", event.timestamp)
      return event
    }
  }

  static func log(_ message: String) {
    guard enabled else { return }
    print("MacSearchTrace " + message)
    fflush(stdout)
  }

  /// The first results render, or the panel shown, after a key.
  static func rendered() {
    guard enabled, let key else { return }
    self.key = nil
    // After SwiftUI's update and Core Animation's commit, the last observers before the main thread sleeps.
    let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, Int.max) { _, _ in
      print(String(format: "MacSearchTrace %@ %.1f ms", key.label, (ProcessInfo.processInfo.systemUptime - key.at) * 1000))
      fflush(stdout)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }
}

/// Hosted checks exercise the actual native field's delegate and the window-owned navigation, even locked.
@MainActor enum MacSearchChecks {
  static func layout(_ runtime: MacWindowRuntime) async -> String? {
    runtime.search.open()
    defer { runtime.search.close(runtime: runtime, focusComposer: false) }
    try? await Task.sleep(for: .milliseconds(250))
    return geometry(runtime)
  }

  static func geometry(_ runtime: MacWindowRuntime) -> String? {
    guard let window = runtime.window, let root = window.contentView?.superview else { return "busca sem janela" }
    func placements(_ view: NSView) -> [MacSearchPlacement] {
      ((view as? MacSearchPlacement).map { [$0] } ?? []) + view.subviews.flatMap(placements)
    }
    guard let placement = placements(root).first, let geometry = placement.geometry,
      let delegate = placement.field.delegate as? MacSearchPresentation.Coordinator else {
      return "geometria da busca ausente"
    }
    let field = placement.field.frame
    guard field.width >= 100, field.width <= 520, abs(field.midX - geometry.detail.midX) < 1,
      field.minX >= geometry.title.maxX + 11, field.maxX <= geometry.actions.minX - 11 else {
      return "busca sobreposta/descentrada: campo=\(field), área=\(geometry.detail), título=\(geometry.title), ações=\(geometry.actions)"
    }
    let screen = window.convertToScreen(placement.field.convert(placement.field.bounds, to: nil))
    guard delegate.panel.isVisible, abs(delegate.panel.frame.width - field.width) < 1,
      abs(delegate.panel.frame.minX - screen.minX) < 1,
      abs(delegate.panel.frame.maxY - (screen.minY - 4)) < 1 else {
      return "lista não ancorada: lista=\(delegate.panel.frame), campo=\(screen)"
    }
    print("MacStress busca geometria: janela=\(Int(window.frame.width)) campo=\(Int(field.width)) centro=\(Int(field.midX)) contexto=\(runtime.contextVisible) sessões=\(runtime.state.sidebarVisible) ok")
    return nil
  }

  static func run(_ runtime: MacWindowRuntime, other: MacWindowRuntime) async -> String? {
    guard let store = runtime.store, let window = runtime.window, let root = window.contentView?.superview else {
      return "busca sem janela"
    }
    func fields(_ view: NSView) -> [NSSearchField] {
      ((view as? NSSearchField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
    }
    guard let field = fields(root).first(where: { $0.accessibilityIdentifier() == "mac-window-search" }),
      let delegate = field.delegate as? MacSearchPresentation.Coordinator else { return "campo nativo ausente" }
    let state = runtime.state
    let otherState = other.state
    let filter = store.filter
    let project = store.selectedProject
    defer {
      runtime.search.close(runtime: runtime)
      runtime.search.query = ""
      runtime.state = state
      store.filter = filter
      store.selectedProject = project
    }
    func command(_ selector: Selector) {
      _ = delegate.control(field, textView: NSTextView(), doCommandBy: selector)
    }
    runtime.search.open()
    try? await Task.sleep(for: .milliseconds(250))
    guard delegate.panel.isVisible, !other.search.visible else { return "busca não abriu só nesta janela" }
    command(#selector(NSResponder.moveDown(_:)))
    guard runtime.search.selection == "project:custom.chats" else { return "seta não selecionou Chats" }
    command(#selector(NSResponder.insertNewline(_:)))
    guard store.chatsSelected, !runtime.search.visible else { return "Return não aplicou Chats" }
    runtime.search.open()
    runtime.search.query = "live"
    let groups = runtime.search.groups
    guard groups.map(\.kind) == [.projects, .sessions, .archived] else { return "busca live sem os três grupos" }
    runtime.search.selectedID = groups.first?.results.last?.id
    command(#selector(NSResponder.moveDown(_:)))
    guard runtime.search.selection == groups[1].results.first?.id else { return "seta não atravessou grupos" }
    command(#selector(NSResponder.insertNewline(_:)))
    guard runtime.selection.sessionID == "ses_mac_live", store.selectedProject == nil, store.filter == .all else {
      return "seleção não abriu sessão oculta em Todas"
    }
    runtime.search.open()
    runtime.search.choose("session:ses_mac_archived", runtime: runtime)
    guard runtime.selection.sessionID == "ses_mac_archived" else { return "não abriu arquivada" }
    runtime.search.open()
    command(#selector(NSResponder.cancelOperation(_:)))
    guard runtime.search.visible, runtime.search.query.isEmpty, field.stringValue.isEmpty else {
      return "Esc com texto não limpou o campo"
    }
    command(#selector(NSResponder.cancelOperation(_:)))
    guard !runtime.search.visible, !delegate.panel.isVisible,
      runtime.drafts.draft("ses_mac_archived").focused else { return "Esc não fechou/devolveu foco" }
    guard other.state == otherState else { return "busca alterou a seleção de outra janela" }
    runtime.search.open()
    try? await Task.sleep(for: .milliseconds(250))
    guard let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 1) else { return "clique de teste indisponível" }
    delegate.mouseDown(click)
    guard !runtime.search.visible, !delegate.panel.isVisible else { return "clicar fora não fechou a busca" }
    runtime.search.open()
    try? await Task.sleep(for: .milliseconds(250))
    // A locked screen cannot elect a key window; the actual notification adapter is still testable there.
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    guard !runtime.search.visible, !delegate.panel.isVisible else { return "trocar de janela não fechou a busca" }
    print("MacStress busca: campo, grupos, setas, Return, filtros, arquivada, Esc, clique fora e isolamento ok")
    return nil
  }
}
#endif
