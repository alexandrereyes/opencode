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
    view.field.focused = { [weak runtime] in
      guard let runtime, !runtime.search.visible else { return }
      runtime.search.visible = true
      runtime.switcherVisible = false
    }
    view.reposition = { [weak coordinator = context.coordinator] in coordinator?.reposition() }
    context.coordinator.placement = view
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak coordinator = context.coordinator] in coordinator?.warm() }
    #if DEBUG
    MacSearchTrace.start()
    #endif
    return view
  }

  func updateNSView(_ view: MacSearchPlacement, context: Context) {
    let field = view.field
    let search = runtime.search
    if field.stringValue != search.query { field.stringValue = search.query }
    field.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
    field.backgroundColor = theme.nsColor(.surface)
    view.schedule()
    // Only what places the panel: the results observe the search themselves, inside the panel's hosting view.
    let rows = search.groups.reduce(0) { $0 + $1.results.count + ($1.hasMore ? 1 : 0) }
    context.coordinator.update(theme: theme, visible: search.visible, focus: search.focusRequest,
      height: CGFloat(min(560, max(96, rows * 50 + search.groups.count * 32 + 48))))
  }

  static func dismantleNSView(_ view: MacSearchPlacement, coordinator: Coordinator) {
    coordinator.stop()
    view.stop()
  }

  @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
    let runtime: MacWindowRuntime
    weak var placement: MacSearchPlacement?
    var field: MacSearchField? { placement?.field }
    /// Created once per window and reused by every opening; only its frame and visibility change.
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let host: NSHostingView<MacSearchResults>
    private var themeID: String?
    private var focus = 0
    private var monitor: Any?
    private var resultsHeight: CGFloat = 96

    init(runtime: MacWindowRuntime) {
      self.runtime = runtime
      host = NSHostingView(rootView: MacSearchResults(search: runtime.search, runtime: runtime, theme: .selected))
      super.init()
      // The field owns the panel width; SwiftUI's intrinsic content size must not resize the NSPanel.
      host.sizingOptions = []
      panel.contentView = host
      panel.identifier = NSUserInterfaceItemIdentifier("mac-search-suggestions")
      panel.isReleasedWhenClosed = false
      panel.hasShadow = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hidesOnDeactivate = true
      NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSWindow.didMoveNotification, object: nil)
    }

    func update(theme: AppTheme, visible: Bool, focus: Int, height: CGFloat) {
      guard visible else { hide(); return }
      if themeID != theme.id {
        themeID = theme.id
        host.rootView = MacSearchResults(search: runtime.search, runtime: runtime, theme: theme)
      }
      resultsHeight = height
      show()
      guard self.focus != focus else { return }
      // After this SwiftUI update: the first responder change makes the composer publish its own focus.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.runtime.search.visible, let field = self.field, let window = field.window else { return }
        self.focus = focus
        if field.currentEditor() == nil || window.firstResponder !== field.currentEditor() {
          window.makeFirstResponder(field)
        }
        field.currentEditor()?.selectAll(nil)
      }
    }

    /// Builds the catalog and lays the results out once while hidden, so the first ⌘K only shows the panel.
    func warm() {
      guard !runtime.search.visible else { return }
      runtime.search.prepare()
      // Transparent and unparented: the window server backing and the material are created without a frame shown.
      panel.alphaValue = 0
      panel.setFrame(NSRect(x: 0, y: 0, width: max(field?.frame.width ?? 0, 320), height: 400), display: false)
      panel.orderFront(nil)
      panel.displayIfNeeded()
      panel.orderOut(nil)
      panel.alphaValue = 1
    }

    private func show() {
      guard let field, let window = field.window else {
        // The title-bar anchors can be installed after the first SwiftUI update.
        DispatchQueue.main.async { [weak self] in if self?.field?.window != nil, self?.runtime.search.visible == true { self?.show() } }
        return
      }
      reposition()
      guard panel.parent !== window || !panel.isVisible else { return }
      #if DEBUG
      MacSearchTrace.rendered()
      #endif
      if panel.parent !== window {
        panel.parent?.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
      }
      panel.orderFront(nil)
      if monitor == nil {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
          self?.mouseDown(event)
          return event
        }
      }
    }

    func mouseDown(_ event: NSEvent) {
      guard let field, event.window !== panel else { return }
      if event.window === field.window && field.convert(field.bounds, to: nil).contains(event.locationInWindow) { return }
      runtime.search.close(runtime: runtime, focusComposer: false)
      hide()
      // A click on something that takes focus (the composer) still does; elsewhere the hidden search lets go.
      if let window = field.window, let editor = field.currentEditor(), window.firstResponder === editor {
        window.makeFirstResponder(nil)
      }
    }

    @objc func reposition() {
      guard let field, let window = field.window, runtime.search.visible else { return }
      let rect = window.convertToScreen(field.convert(field.bounds, to: nil))
      let height = min(resultsHeight, max(96, rect.minY - window.frame.minY - 12))
      let frame = NSRect(x: rect.minX, y: rect.minY - height - 4, width: rect.width, height: height)
      if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    @objc private func windowResigned(_ notification: Notification) {
      guard notification.object as? NSWindow === field?.window else { return }
      runtime.search.close(runtime: runtime, focusComposer: false)
      hide()
    }

    func controlTextDidChange(_ notification: Notification) {
      runtime.search.query = field?.stringValue ?? ""
      if !runtime.search.visible { runtime.search.visible = true }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      let search = runtime.search
      switch command {
      // ⌃N and ⌃P reach here as moveDown:/moveUp: through the standard key bindings.
      case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
        if search.visible { search.move(command == #selector(NSResponder.moveDown(_:)) ? 1 : -1) }
        else { search.visible = true }
      case #selector(NSResponder.insertNewline(_:)):
        search.choose(runtime: runtime)
      case #selector(NSResponder.cancelOperation(_:)):
        if search.query.isEmpty {
          search.close(runtime: runtime)
        } else {
          search.query = ""
          field?.stringValue = ""
        }
      default: return false
      }
      if !search.visible { hide() }
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

/// The panel's content. It reads the search directly, so a keystroke re-renders the visible rows only.
struct MacSearchResults: View {
  let search: MacSearch
  let runtime: MacWindowRuntime
  let theme: AppTheme

  var body: some View {
    MacSearchList(search: search, runtime: runtime)
      .environment(\.appTheme, theme).environment(\.colorScheme, theme.dark ? .dark : .light)
      .sessionRowTimeline()
  }
}

private struct MacSearchList: View {
  @Environment(\.appTheme) private var theme
  let search: MacSearch
  let runtime: MacWindowRuntime
  @State private var compact = false

  var body: some View {
    #if DEBUG
    let _ = MacSearchTrace.rendered()
    #endif
    let groups = search.groups
    let selected = search.selection
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 0).id("search-top")
            if groups.isEmpty {
              Text("Nenhum resultado").foregroundStyle(theme.color(.textSecondary)).padding(16)
            }
            ForEach(groups) { group in
              section(group, first: group.id == groups.first?.id, selected: selected)
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

  @ViewBuilder private func section(_ group: WindowSearch.Group, first: Bool, selected: String?) -> some View {
    if !first {
      Rectangle().fill(theme.color(.border)).frame(height: 1).padding(.horizontal, 8).padding(.top, 4)
    }
    Text(group.kind == .archived ? "ARQUIVADAS" : group.kind.rawValue.uppercased())
      .font(.system(size: 10, weight: .semibold)).tracking(0.8)
      .foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    ForEach(group.results) { result in row(result, kind: group.kind, selected: result.id == selected) }
    if group.hasMore {
      let id = search.moreID(group.kind)
      Button("Mostrar mais · \(group.total)") { search.choose(id, runtime: runtime) }
        .buttonStyle(.plain).font(.system(size: 12)).padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(id == selected ? theme.color(.highlight) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(group.kind.rawValue + ", Mostrar mais")
        .accessibilityAddTraits(id == selected ? .isSelected : [])
        .id(id)
    }
  }

  private func row(_ result: WindowSearch.Result, kind: WindowSearch.Kind, selected: Bool) -> some View {
    let catalog = search.catalog
    let session: Session? = if case .session(let id) = result.target { catalog?.session(id) } else { nil }
    return Button { search.choose(result.id, runtime: runtime) } label: {
      HStack(spacing: 10) {
        avatar(result, kind: kind, session: session, catalog: catalog)
        title(result, kind: kind, session: session, catalog: catalog)
        if let session { status(at: result.activity, running: catalog?.running.contains(session.id) == true) }
      }.padding(.horizontal, 10).frame(height: 48).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(.text))
    .background(selected ? theme.color(.highlight) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityLabel(kind.rawValue + ", " + result.title + ", " + result.detail)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .id(result.id)
  }

  private func title(_ result: WindowSearch.Result, kind: WindowSearch.Kind, session: Session?,
    catalog: MacSearch.Catalog?) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(highlight(result.title)).font(.system(size: 13)).lineLimit(1)
      if case .project(let id) = result.target {
        let count = catalog?.counts[id ?? ""] ?? 0
        Text(count == 1 ? "1 sessão" : "\(count) sessões")
          .font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
      } else if kind != .archived, let session {
        SessionDirectoryLine(label: catalog?.labels[session.id])
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

  @ViewBuilder private func avatar(_ result: WindowSearch.Result, kind: WindowSearch.Kind, session: Session?,
    catalog: MacSearch.Catalog?) -> some View {
    if kind == .archived {
      Image(systemName: "archivebox").font(.system(size: 18)).frame(width: 36)
        .foregroundStyle(theme.color(.textSecondary))
    } else {
      let id: String? = if case .project(let id) = result.target { id } else { session?.projectID }
      if let id, let project = catalog?.projects[id], session.flatMap({ catalog?.rows[$0.id]?.chat }) != true {
        ProjectAvatar(project: project, size: 36, style: .secondary)
      } else {
        Image(systemName: id == nil ? "square.grid.2x2" : "bubble.left")
          .font(.system(size: 17)).foregroundStyle(theme.color(.textSecondary))
          .frame(width: 36, height: 36).background(theme.color(.highlight), in: Circle())
      }
    }
  }
}
