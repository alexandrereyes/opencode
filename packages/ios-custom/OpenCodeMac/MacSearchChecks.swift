#if DEBUG
import AppKit
import OpenCodeKit

/// Hosted checks exercise the actual native field's delegate and the window-owned navigation, even locked.
@MainActor enum MacSearchChecks {
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
    guard runtime.search.selection(store) == "project:custom.chats" else { return "seta não selecionou Chats" }
    command(#selector(NSResponder.insertNewline(_:)))
    guard store.chatsSelected, !runtime.search.visible else { return "Return não aplicou Chats" }
    runtime.search.open()
    runtime.search.query = "live"
    let groups = runtime.search.groups(store)
    guard groups.map(\.kind) == [.projects, .sessions, .archived] else { return "busca live sem os três grupos" }
    runtime.search.selectedID = groups.first?.results.last?.id
    command(#selector(NSResponder.moveDown(_:)))
    guard runtime.search.selection(store) == groups[1].results.first?.id else { return "seta não atravessou grupos" }
    command(#selector(NSResponder.insertNewline(_:)))
    guard runtime.selection.sessionID == "ses_mac_live", store.selectedProject == nil, store.filter == .all else {
      return "seleção não abriu sessão oculta em Todas"
    }
    runtime.search.open()
    runtime.search.choose("session:ses_mac_archived", runtime: runtime)
    guard runtime.selection.sessionID == "ses_mac_archived" else { return "não abriu arquivada" }
    runtime.search.open()
    command(#selector(NSResponder.cancelOperation(_:)))
    guard !runtime.search.visible, !delegate.panel.isVisible,
      runtime.drafts.draft("ses_mac_archived").focused else { return "Esc não fechou/devolveu foco" }
    guard other.state == otherState else { return "busca alterou a seleção de outra janela" }
    print("MacStress busca: campo, grupos, setas, Return, filtros, arquivada, Esc e isolamento ok")
    return nil
  }
}
#endif
