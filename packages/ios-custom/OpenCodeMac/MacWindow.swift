import OpenCodeKit
import SwiftUI

/// The main window: Sessões | chat in a split view, and Contexto beside the chat in the detail column, behind a
/// draggable hairline. Contexto hides with ⌥⌘I, Visualizar or the `…` menu; Sessões with ⌃⌘S.
struct MacWindow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Bindable var store: SessionStore
  @Bindable var runtime: MacWindowRuntime
  @State private var context: ContextColumnStore?
  /// The columns of the sessions shown last (the root under an open subagent, its ancestors), most recent first:
  /// going back shows the root's column at once while it reloads.
  @State private var contexts: [ContextColumnStore] = []
  @State private var detailWidth: CGFloat = 860
  @State private var windowWidth: CGFloat = 1500
  @State private var windowHeight: CGFloat = 940

  /// How wide Contexto may be now: up to 60% of the window, never squeezing the chat below its minimum.
  private var contextRange: ClosedRange<Double> {
    DesktopWindowState.contextWidthRange(detail: detailWidth, window: windowWidth, chatMinimum: chatMinimum)
  }
  // With both side columns hidden, traffic lights and the sidebar's toolbar still precede the title.
  private var chatMinimum: CGFloat { !runtime.state.sidebarVisible && !runtime.contextVisible ? 840 : 460 }

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("MacWindow")
    #endif
    NavigationSplitView(columnVisibility: $runtime.columns) {
      MacSessionColumn(store: store, runtime: runtime)
        .navigationSplitViewColumnWidth(min: 352, ideal: 382, max: 532)
        .background(MacSidebarDivider(visible: runtime.state.sidebarVisible))
    } detail: {
      // Contexto shares the detail column with the chat instead of being an inspector: an inspector gets its
      // own, empty part of the title bar, while the approved window has one strip with `…` and Nova sessão
      // over Contexto.
      HStack(spacing: 0) {
        // The title takes the room up to the search at its full 520 pt (centered on the detail), up to 480 pt, so a
        // long title or worktree name is cut only when the bar is really narrow.
        MacChatColumn(store: store, runtime: runtime, context: context,
          titleWidth: min(480, max(100, (detailWidth - 520) / 2 - 32 - (runtime.state.sidebarVisible ? 0 : 180))))
          // Keep this minimum on the chat, never on the root (which causes AppKit constraint loops).
          .frame(minWidth: chatMinimum, maxWidth: .infinity)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { runtime.measuredChatWidth = $0 }
        if runtime.contextVisible {
          let wide = runtime.filesWide && runtime.selection.files != nil
          if wide {
            Rectangle().fill(theme.color(.border)).frame(width: 1)
          } else {
            MacColumnDivider(width: $runtime.contextWidth, range: contextRange) { width in
              if !MacLaunch.fixture { DesktopWindowState.rememberContextWidth(width, defaults: .standard) }
            }
          }
          // Offered the room first, up to the dragged width (at most 60% of the window); a narrower window shrinks
          // it to 400 pt before the chat goes below its 460, so the window's minimum stays the two minimums.
          // Widened Arquivos takes everything but the chat's minimum, past the 60%.
          inspector.frame(minWidth: wide ? max(400, detailWidth - chatMinimum - 1) : 400,
            maxWidth: wide ? max(400, detailWidth - chatMinimum - 1)
              : max(400, min(runtime.contextWidth, windowWidth * DesktopWindowState.maximumContextShare)))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { runtime.measuredContextWidth = $0 }
            .layoutPriority(1)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
      .background(MacSearchPresentation(runtime: runtime))
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
    .background(theme.color(.background))
    .toastOverlay(store.toast)
    // No in-app banner on the Mac: the title bar's bell lists the alerts (`MacNotificationBell`), so no
    // `sessionAlerts` context is set and shared screens' overlays stay empty.
    .sessionRowTimeline()
    // Nova sessão and the archive confirmation belong to the window, so they open with Sessões collapsed too.
    .sheet(item: $runtime.newSessionRequest) { request in
      MacNewSession(store: store, runtime: runtime, request: request)
    }
    .sheet(isPresented: $runtime.shortcutsVisible) { MacShortcutsSheet() }
    .sheet(isPresented: $runtime.diskVisible) {
      MacDiskSheet(disk: runtime.app.disk, sessions: store, window: CGSize(width: windowWidth, height: windowHeight))
    }
    .sheet(isPresented: $runtime.proxyVisible) {
      MacProxySheet(runtime: runtime.app, window: CGSize(width: windowWidth, height: windowHeight))
    }
    .confirmationDialog(
      "Arquivar sessão?",
      isPresented: Binding(get: { runtime.archiveRequest != nil }, set: { if !$0 { runtime.archiveRequest = nil } })
    ) {
      if let row = runtime.archiveRequest {
        Button("Arquivar", role: .destructive) {
          Task { await store.archive(row) }
          runtime.archiveRequest = nil
        }
      }
      Button("Cancelar", role: .cancel) { runtime.archiveRequest = nil }
    } message: {
      Text("A sessão sairá de Recentes e ficará na lista de arquivadas. Não há opção de desarquivar nesta versão.")
    }
    // The call belongs to the app; this window owns its bar presentation and composer inset.
    .modifier(MacVoiceWindow(runtime: runtime))
    .focusedSceneValue(\.macWindow, runtime)
    .background(MacWindowConnection(runtime: runtime))
    .onChange(of: store.deletedIDs) { _, ids in
      Task { try? await runtime.drafts.remove(ids) }
    }
    #if DEBUG
    .onChange(of: scenePhase, initial: true) { _, phase in
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacLiveTrace") { macTrace("scenePhase \(phase)") }
    }
    #endif
    // Contexto follows the session open in the middle column: the subagent over the root while one is open. Only
    // the shown column listens to the event stream.
    .task(id: runtime.selection.childID ?? runtime.selection.sessionID) {
      guard let id = runtime.selection.childID ?? runtime.selection.sessionID else {
        context = nil
        return
      }
      let next = contexts.first { $0.id == id } ?? ContextColumnStore(id: id, sessions: store)
      contexts = [next] + contexts.filter { $0 !== next }.prefix(3)
      context = next
      await next.run()
    }
    // In a view of its own: reading the rows here would re-evaluate the whole window on every list change.
    .background(MacSelectionKeeper(store: store, runtime: runtime))
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      runtime.app.syncShown()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      runtime.app.syncShown()
    }
    .onAppear { runtime.app.syncShown() }
    #if DEBUG
    .task {
      if MacProxyLaunch.pane != nil, MacCapture.folder != nil { runtime.showProxy() }
      await MacCapture.window(context: { context }, runtime: runtime, theme: theme, openWindow: openWindow,
        openSettings: openSettings)
    }
    .task { await MacStress.run(runtime: runtime, openWindow: openWindow) }
    .task { await MacVoiceScreenCheck.run(runtime) }
    .task { await MacDiskChecks.run(runtime: runtime, store: store) }
    .task { await MacPerf.run(runtime: runtime) }
    #endif
  }

  /// Contexto, at the width the divider beside it sets.
  private var inspector: some View {
    Group {
      if let context {
        MacContextColumn(store: context, runtime: runtime)
      } else {
        ContentUnavailableView("Nenhuma sessão", systemImage: "sidebar.right",
          description: Text("Escolha uma sessão para ver o contexto."))
          .foregroundStyle(theme.color(.textSecondary))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.color(.background))
  }

}

/// Keeps the window on a session as the list changes: the one it reopens on while it still exists, else the first row.
private struct MacSelectionKeeper: View {
  let store: SessionStore
  let runtime: MacWindowRuntime
  @State private var restored = false

  var body: some View {
    Color.clear.onChange(of: store.rows.map(\.id), initial: true) { _, ids in
      guard !ids.isEmpty else { return }
      #if DEBUG
      if runtime.selection.sessionID == nil, let id = MacFixture.value("-OpenCodeMacSession") {
        runtime.selection.sessionID = id
        // `-OpenCodeMacChildAfter <s>` opens the child that long after the root, as a click on its chip would.
        if let child = MacFixture.value("-OpenCodeMacChild") {
          if let delay = MacFixture.value("-OpenCodeMacChildAfter").flatMap(Double.init) {
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(delay))
              runtime.selection.childID = child
            }
          } else {
            runtime.selection.childID = child
          }
        }
        if let folder = MacFixture.value("-OpenCodeMacFiles") { runtime.showFiles(at: folder) }
        return
      }
      #endif
      // The window reopens on the session it showed; one that is gone since (deleted, archived) falls back to
      // the first row, like a first launch.
      if !restored, let id = runtime.selection.sessionID, !runtime.selection.master, !ids.contains(id) {
        runtime.selection = MacSelection()
      }
      restored = true
      guard runtime.selection.sessionID == nil else { return }
      runtime.selection.sessionID = SessionSections.group(store.filtered, now: .now)
        .first?.rows.first?.id
    }
  }
}

/// The hairline between the chat and Contexto; dragging it resizes Contexto within `range`, and the width it ends
/// at is remembered (`ended`).
struct MacColumnDivider: View {
  @Environment(\.appTheme) private var theme
  @Binding var width: Double
  let range: ClosedRange<Double>
  /// The resized column is on the divider's left (Arquivos' tree) instead of its right (Contexto).
  var leading = false
  let ended: (Double) -> Void
  @State private var start: Double?

  var body: some View {
    Rectangle().fill(theme.color(.border)).frame(width: 1)
      .overlay {
        MacColumnGrip(highlight: theme.nsColor(.primary)) { translation in
          // A width remembered from a wider window starts the drag from what is shown.
          let origin = start ?? min(max(width, range.lowerBound), range.upperBound)
          start = origin
          width = min(max(leading ? origin + translation : origin - translation, range.lowerBound), range.upperBound)
        } ended: {
          start = nil
          ended(width)
        }
        .frame(width: 15)
        // The hosting view sets the pointer over its content; this keeps it a resize pointer over the grip.
        .pointerStyle(.columnResize)
      }
      // Above Contexto, which the grip's right half overlaps.
      .zIndex(1)
      .accessibilityHidden(true)
  }
}

/// The divider's grab area, in AppKit: the transcript and Contexto's scroll views are AppKit views, which win hit
/// testing and cursor updates over a SwiftUI shape, so a SwiftUI grab area beside them was mostly unreachable.
/// Hovering or dragging it shows a 3-pt line in the theme's primary color, so the grab area is visible.
private struct MacColumnGrip: NSViewRepresentable {
  let highlight: NSColor
  let changed: (Double) -> Void
  let ended: () -> Void

  func makeNSView(context: Context) -> Grip { Grip() }
  func updateNSView(_ view: Grip, context: Context) {
    view.changed = changed
    view.ended = ended
    view.line.layer?.backgroundColor = highlight.cgColor
  }

  final class Line: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  final class Grip: NSView {
    var changed: (Double) -> Void = { _ in }
    var ended: () -> Void = {}
    let line = Line()
    private var origin: CGFloat?
    private var hovered = false

    override init(frame: NSRect) {
      super.init(frame: frame)
      line.wantsLayer = true
      line.alphaValue = 0
      addSubview(line)
    }
    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
      line.frame = NSRect(x: bounds.midX - 1.5, y: 0, width: 3, height: bounds.height)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: .zero,
        options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseEntered(with event: NSEvent) {
      hovered = true
      NSCursor.resizeLeftRight.set()
      refresh()
    }
    // Views around the grip set their own pointer as the mouse moves.
    override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseExited(with event: NSEvent) {
      hovered = false
      if origin == nil { NSCursor.arrow.set() }
      refresh()
    }
    override func mouseDown(with event: NSEvent) {
      origin = event.locationInWindow.x
      refresh()
    }
    override func mouseDragged(with event: NSEvent) {
      guard let origin else { return }
      NSCursor.resizeLeftRight.set()
      changed(event.locationInWindow.x - origin)
    }
    override func mouseUp(with event: NSEvent) {
      guard origin != nil else { return }
      origin = nil
      if !hovered { NSCursor.arrow.set() }
      refresh()
      ended()
    }

    private func refresh() {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.12
        line.animator().alphaValue = hovered || origin != nil ? 1 : 0
      }
    }
  }
}
