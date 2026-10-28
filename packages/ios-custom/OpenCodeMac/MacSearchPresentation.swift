import AppKit
import OpenCodeKit
import SwiftUI

/// Provisional A: a native search field and a nonactivating suggestions panel, keeping typing in the title bar.
/// Replace this adapter for B/C; ranking, filters and navigation live in WindowSearch and MacSearch.
struct MacSearchPresentation: NSViewRepresentable {
  @Environment(\.appTheme) private var theme
  let runtime: MacWindowRuntime

  func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Buscar · ⌘K"
    field.setAccessibilityLabel("Buscar projetos e sessões")
    field.setAccessibilityIdentifier("mac-window-search")
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.controlSize = .regular
    context.coordinator.field = field
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    let search = runtime.search
    if field.stringValue != search.query { field.stringValue = search.query }
    // Read observed values here so the AppKit adapter updates with streaming data and keyboard selection too.
    let groups = runtime.store.map(search.groups) ?? []
    let selected = runtime.store.flatMap(search.selection)
    context.coordinator.update(theme: theme, groups: groups, selected: selected,
      visible: search.visible, focus: search.focusRequest)
  }

  static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { coordinator.stop() }

  @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
    let runtime: MacWindowRuntime
    weak var field: NSSearchField?
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var focus = 0
    private var monitor: Any?

    init(runtime: MacWindowRuntime) {
      self.runtime = runtime
      super.init()
      panel.identifier = NSUserInterfaceItemIdentifier("mac-search-suggestions")
      panel.isReleasedWhenClosed = false
      panel.hasShadow = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hidesOnDeactivate = true
      NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSWindow.didResizeNotification, object: nil)
    }

    func update(theme: AppTheme, groups: [WindowSearch.Group], selected: String?, visible: Bool, focus: Int) {
      guard visible else { hide(); return }
      let content = MacSearchResults(search: runtime.search, runtime: runtime, groups: groups, selected: selected)
        .environment(\.appTheme, theme).environment(\.colorScheme, theme.dark ? .dark : .light)
      panel.contentView = NSHostingView(rootView: content)
      let count = groups.reduce(0) { $0 + $1.results.count + ($1.hasMore ? 1 : 0) }
      panel.setContentSize(NSSize(width: 430, height: min(560, max(96, count * 50 + groups.count * 28 + 16))))
      // A toolbar item can be installed after the first SwiftUI update.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.runtime.search.visible, let field = self.field, let window = field.window else { return }
        if self.focus != focus {
          self.focus = focus
          window.makeFirstResponder(field)
          field.selectText(nil)
        }
        if self.panel.parent !== window { window.addChildWindow(self.panel, ordered: .above) }
        self.reposition()
        self.panel.orderFront(nil)
        if self.monitor == nil {
          self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel,
              !(event.window === field.window && field.convert(field.bounds, to: nil).contains(event.locationInWindow)) {
              self.runtime.search.close(runtime: self.runtime, focusComposer: false)
              self.hide()
            }
            return event
          }
        }
      }
    }

    @objc private func reposition() {
      guard let field, let window = field.window, runtime.search.visible else { return }
      let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
      panel.setFrameOrigin(NSPoint(x: rect.maxX - panel.frame.width, y: rect.minY - panel.frame.height - 6))
    }

    @objc private func windowResigned(_ notification: Notification) {
      guard notification.object as? NSWindow === field?.window else { return }
      runtime.search.close(runtime: runtime, focusComposer: false)
      hide()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      runtime.search.visible = true
      runtime.switcherVisible = false
    }

    func controlTextDidChange(_ notification: Notification) {
      runtime.search.query = field?.stringValue ?? ""
      runtime.search.visible = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      guard let store = runtime.store else { return false }
      switch command {
      case #selector(NSResponder.moveDown(_:)): runtime.search.move(1, store: store)
      case #selector(NSResponder.moveUp(_:)): runtime.search.move(-1, store: store)
      case #selector(NSResponder.insertNewline(_:)): runtime.search.choose(runtime: runtime)
      case #selector(NSResponder.cancelOperation(_:)): runtime.search.close(runtime: runtime)
      default: return false
      }
      if !runtime.search.visible { hide() }
      return true
    }

    private func hide() {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    func stop() { hide(); NotificationCenter.default.removeObserver(self) }
  }
}

private struct MacSearchResults: View {
  @Environment(\.appTheme) private var theme
  let search: MacSearch
  let runtime: MacWindowRuntime
  let groups: [WindowSearch.Group]
  let selected: String?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if groups.isEmpty {
            Text("Nenhum resultado").foregroundStyle(theme.color(.textSecondary)).padding(16)
          }
          ForEach(groups) { group in
            section(group)
          }
        }.padding(8)
      }
      .onChange(of: selected, initial: true) { _, id in if let id { proxy.scrollTo(id) } }
    }
    .background(theme.color(.background), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 1) }
  }

  @ViewBuilder private func section(_ group: WindowSearch.Group) -> some View {
    Text(group.kind.rawValue).font(.system(size: 11, weight: .semibold))
      .foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    ForEach(group.results) { result in row(result, kind: group.kind) }
    if group.hasMore {
      let id = search.moreID(group.kind)
      Button("Mostrar mais · \(group.total)") { search.choose(id, runtime: runtime) }
        .buttonStyle(.plain).font(.system(size: 12)).padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(id == selected ? theme.color(.highlight) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(group.kind.rawValue + ", Mostrar mais").id(id)
    }
  }

  private func row(_ result: WindowSearch.Result, kind: WindowSearch.Kind) -> some View {
    Button { search.choose(result.id, runtime: runtime) } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol(kind, result.target)).frame(width: 20)
          .foregroundStyle(theme.color(.textSecondary))
        VStack(alignment: .leading, spacing: 3) {
          Text(highlight(result.title)).font(.system(size: 13)).lineLimit(1)
          Text(result.detail).font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }
        Spacer(minLength: 0)
        if result.id == selected { Image(systemName: "return").font(.system(size: 11)) }
      }.padding(.horizontal, 10).frame(height: 48).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(.text))
    .background(result.id == selected ? theme.color(.highlight) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityLabel(kind.rawValue + ", " + result.title + ", " + result.detail)
    .accessibilityAddTraits(result.id == selected ? .isSelected : [])
    .id(result.id)
  }

  private func highlight(_ title: String) -> AttributedString {
    var text = AttributedString(title)
    for range in WindowSearch.highlights(in: title, query: search.query) {
      if let range = Range(range, in: text) { text[range].font = .system(size: 13, weight: .bold) }
    }
    return text
  }

  private func symbol(_ kind: WindowSearch.Kind, _ target: WindowSearch.Target) -> String {
    if case .project(let id) = target { return id == nil ? "square.stack" : id == WindowSearch.chats ? "bubble.left" : "folder" }
    return kind == .archived ? "archivebox" : "bubble.left.and.bubble.right"
  }
}
