import AppKit
import OpenCodeKit
import SwiftUI

/// Centered native field and anchored, nonactivating results. Ranking and navigation stay in MacSearch.
struct MacSearchPresentation: NSViewRepresentable {
  @Environment(\.appTheme) private var theme
  let runtime: MacWindowRuntime

  func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime) }

  func makeNSView(context: Context) -> MacSearchPlacement {
    let view = MacSearchPlacement()
    view.field.delegate = context.coordinator
    view.reposition = { [weak coordinator = context.coordinator] in coordinator?.reposition() }
    context.coordinator.placement = view
    return view
  }

  func updateNSView(_ view: MacSearchPlacement, context: Context) {
    let field = view.field
    let search = runtime.search
    if field.stringValue != search.query { field.stringValue = search.query }
    field.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
    field.backgroundColor = theme.nsColor(.surface)
    view.schedule()
    // Read observed values here so the AppKit adapter updates with streaming data and keyboard selection too.
    let groups = runtime.store.map(search.groups) ?? []
    let selected = runtime.store.flatMap(search.selection)
    context.coordinator.update(theme: theme, groups: groups, selected: selected,
      visible: search.visible, focus: search.focusRequest)
  }

  static func dismantleNSView(_ view: MacSearchPlacement, coordinator: Coordinator) {
    coordinator.stop()
    view.stop()
  }

  @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
    let runtime: MacWindowRuntime
    weak var placement: MacSearchPlacement?
    var field: NSSearchField? { placement?.field }
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var focus = 0
    private var monitor: Any?
    private var resultsHeight: CGFloat = 96

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
      NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSWindow.didMoveNotification, object: nil)
    }

    func update(theme: AppTheme, groups: [WindowSearch.Group], selected: String?, visible: Bool, focus: Int) {
      guard visible else { hide(); return }
      let content = MacSearchResults(search: runtime.search, runtime: runtime, groups: groups, selected: selected)
        .environment(\.appTheme, theme).environment(\.colorScheme, theme.dark ? .dark : .light)
        .sessionRowTimeline()
      let host = NSHostingView(rootView: content)
      // The field owns the panel width; SwiftUI's intrinsic content size must not resize the NSPanel.
      host.sizingOptions = []
      panel.contentView = host
      let count = groups.reduce(0) { $0 + $1.results.count + ($1.hasMore ? 1 : 0) }
      resultsHeight = CGFloat(min(560, max(96, count * 50 + groups.count * 32 + 48)))
      // The title-bar anchors can be installed after the first SwiftUI update.
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
            self?.mouseDown(event)
            return event
          }
        }
      }
    }

    func mouseDown(_ event: NSEvent) {
      guard let field, event.window !== panel else { return }
      if event.window === field.window && field.convert(field.bounds, to: nil).contains(event.locationInWindow) { return }
      runtime.search.close(runtime: runtime, focusComposer: false)
      hide()
    }

    @objc func reposition() {
      guard let field, let window = field.window, runtime.search.visible else { return }
      let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
      let height = min(resultsHeight, max(96, rect.minY - window.frame.minY - 12))
      panel.setFrame(NSRect(x: rect.minX, y: rect.minY - height - 4, width: rect.width, height: height), display: true)
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
  @State private var compact = false

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 0).id("search-top")
            if groups.isEmpty {
              Text("Nenhum resultado").foregroundStyle(theme.color(.textSecondary)).padding(16)
            }
            ForEach(groups) { group in
              section(group)
            }
          }.padding(8)
        }
        .onChange(of: selected, initial: true) { _, id in
          if id == groups.first?.results.first?.id { proxy.scrollTo("search-top", anchor: .top) }
          else if let id { proxy.scrollTo(id) }
        }
      }
      Rectangle().fill(theme.color(.border)).frame(height: 1)
      Text("↑↓ navegar · ↩ abrir · esc fechar")
        .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity).frame(height: 31)
    }
    .background(theme.color(.background).opacity(0.72))
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 1) }
    .onGeometryChange(for: Bool.self) { $0.size.width < 320 } action: { compact = $0 }
  }

  @ViewBuilder private func section(_ group: WindowSearch.Group) -> some View {
    if group.id != groups.first?.id {
      Rectangle().fill(theme.color(.border)).frame(height: 1).padding(.horizontal, 8).padding(.top, 4)
    }
    Text(group.kind == .archived ? "ARQUIVADAS" : group.kind.rawValue.uppercased())
      .font(.system(size: 10, weight: .semibold)).tracking(0.8)
      .foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
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
    let session = session(result)
    let running = session.map { session in
      runtime.store?.active.contains(session.id) == true
        || runtime.store?.rows.first(where: { $0.id == session.id })?.state == .running
    } ?? false
    return Button { search.choose(result.id, runtime: runtime) } label: {
      HStack(spacing: 10) {
        avatar(result, kind: kind, session: session)
        title(result, kind: kind, session: session)
        if session != nil { status(at: result.activity, running: running) }
      }.padding(.horizontal, 10).frame(height: 48).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(.text))
    .background(result.id == selected ? theme.color(.highlight) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityLabel(kind.rawValue + ", " + result.title + ", " + result.detail)
    .accessibilityAddTraits(result.id == selected ? .isSelected : [])
    .id(result.id)
  }

  private func title(_ result: WindowSearch.Result, kind: WindowSearch.Kind, session: Session?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(highlight(result.title)).font(.system(size: 13)).lineLimit(1)
      if case .project(let id) = result.target {
        let count = sessionCount(id)
        Text(count == 1 ? "1 sessão" : "\(count) sessões")
          .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
      } else if kind != .archived, let session {
        SessionDirectoryLine(label: runtime.store?.directoryLabel(session))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func status(at: Double, running: Bool) -> some View {
    VStack(alignment: .trailing, spacing: 3) {
      SessionRowTime(at: at)
      if running {
        HStack(spacing: 4) {
          Circle().fill(theme.color(.success)).frame(width: 6, height: 6)
          if !compact {
            Text("trabalhando").font(.system(size: 11)).foregroundStyle(theme.color(.success)).lineLimit(1)
          }
        }
        .accessibilityLabel("Trabalhando")
      }
    }
  }

  private func highlight(_ title: String) -> AttributedString {
    var text = AttributedString(title)
    for range in WindowSearch.highlights(in: title, query: search.query) {
      if let range = Range(range, in: text) { text[range].font = .system(size: 13, weight: .bold) }
    }
    return text
  }

  private func session(_ result: WindowSearch.Result) -> Session? {
    guard case .session(let id) = result.target, let store = runtime.store else { return nil }
    return store.rows.first { $0.id == id }?.session ?? store.archived.first { $0.id == id }
  }

  private func sessionCount(_ project: String?) -> Int {
    guard let store = runtime.store else { return 0 }
    return store.rows.filter { row in
      guard row.session.parentID == nil, row.session.time.archived == nil else { return false }
      guard let project else { return true }
      if project == WindowSearch.chats { return row.chat }
      return !row.chat && row.project?.id == project
    }.count
  }

  @ViewBuilder private func avatar(_ result: WindowSearch.Result, kind: WindowSearch.Kind, session: Session?) -> some View {
    if kind == .archived {
      Image(systemName: "archivebox").font(.system(size: 18)).frame(width: 36)
        .foregroundStyle(theme.color(.textSecondary))
    } else {
      let id: String? = if case .project(let id) = result.target { id } else { session?.projectID }
      if let project = runtime.store?.projects.first(where: { $0.id == id }),
        runtime.store?.rows.first(where: { $0.id == session?.id })?.chat != true {
        ProjectAvatar(project: project, size: 36, style: .secondary)
      } else {
        Image(systemName: id == nil ? "square.grid.2x2" : "bubble.left")
          .font(.system(size: 17)).foregroundStyle(theme.color(.textSecondary))
          .frame(width: 36, height: 36).background(theme.color(.highlight), in: Circle())
      }
    }
  }
}
