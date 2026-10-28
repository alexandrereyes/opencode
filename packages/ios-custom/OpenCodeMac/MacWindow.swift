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
  @State private var restored = false
  @State private var detailWidth: CGFloat = 860
  @State private var windowWidth: CGFloat = 1500

  /// How wide Contexto may be now: up to 60% of the window, never squeezing the chat below its minimum.
  private var contextRange: ClosedRange<Double> {
    DesktopWindowState.contextWidthRange(detail: detailWidth, window: windowWidth, chatMinimum: chatMinimum)
  }
  // With both side columns hidden, traffic lights and the sidebar's toolbar still precede the title.
  private var chatMinimum: CGFloat { !runtime.state.sidebarVisible && !runtime.contextVisible ? 840 : 460 }

  var body: some View {
    NavigationSplitView(columnVisibility: $runtime.columns) {
      MacSessionColumn(store: store, runtime: runtime)
        .navigationSplitViewColumnWidth(min: 352, ideal: 382, max: 532)
        .background(MacSidebarDivider(visible: runtime.state.sidebarVisible))
    } detail: {
      // Contexto shares the detail column with the chat instead of being an inspector: an inspector gets its
      // own, empty part of the title bar, while the approved window has one strip with `…` and Nova sessão
      // over Contexto.
      HStack(spacing: 0) {
        // Reserve a useful search area before allowing a long session title to fill the bar.
        MacChatColumn(store: store, runtime: runtime, context: context,
          titleWidth: min(230, max(100, (detailWidth - 520) / 2 - 32 - (runtime.state.sidebarVisible ? 0 : 180))))
          // Keep this minimum on the chat, never on the root (which causes AppKit constraint loops).
          .frame(minWidth: chatMinimum, maxWidth: .infinity)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { runtime.measuredChatWidth = $0 }
        if runtime.contextVisible {
          MacColumnDivider(width: $runtime.contextWidth, range: contextRange) { width in
            if !MacLaunch.fixture { DesktopWindowState.rememberContextWidth(width, defaults: .standard) }
          }
          // Offered the room first, up to the dragged width (at most 60% of the window); a narrower window shrinks
          // it to 400 pt before the chat goes below its 460, so the window's minimum stays the two minimums.
          inspector.frame(minWidth: 400,
            maxWidth: max(400, min(runtime.contextWidth, windowWidth * DesktopWindowState.maximumContextShare)))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { runtime.measuredContextWidth = $0 }
            .layoutPriority(1)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
      .background(MacSearchPresentation(runtime: runtime))
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
    .background(theme.color(.background))
    .toastOverlay(store.toast)
    .sessionAlertOverlay(modal: false)
    .environment(\.sessionAlerts, SessionAlertsContext(center: store.alerts, open: { id in
      store.alerts.openingSession()
      runtime.select(id)
    }))
    .sessionRowTimeline()
    // Nova sessão and the archive confirmation belong to the window, so they open with Sessões collapsed too.
    .sheet(item: $runtime.newSessionRequest) { request in
      MacNewSession(store: store, runtime: runtime, request: request)
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
    .task(id: runtime.selection.sessionID) {
      guard let id = runtime.selection.sessionID else {
        context = nil
        return
      }
      let next = ContextColumnStore(id: id, sessions: store)
      context = next
      await next.run()
    }
    .onChange(of: store.rows.map(\.id), initial: true) { _, ids in
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
      runtime.selection.sessionID = SessionSections.group(store.filtered, chats: store.chatsSelected, now: .now)
        .first?.rows.first?.id
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      runtime.app.syncShown()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
      runtime.app.syncShown()
    }
    .onAppear { runtime.app.syncShown() }
    #if DEBUG
    .task {
      if MacProxyLaunch.pane != nil, MacCapture.folder != nil { openWindow(id: MacProxyWindow.id) }
      await MacCapture.window(context: { context }, runtime: runtime, theme: theme, openWindow: openWindow,
        openSettings: openSettings)
    }
    .task { await MacStress.run(runtime: runtime, openWindow: openWindow) }
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

/// The hairline between the chat and Contexto; dragging it resizes Contexto within `range`, and the width it ends
/// at is remembered (`ended`).
private struct MacColumnDivider: View {
  @Environment(\.appTheme) private var theme
  @Binding var width: Double
  let range: ClosedRange<Double>
  let ended: (Double) -> Void
  @State private var start: Double?

  var body: some View {
    Rectangle().fill(theme.color(.border)).frame(width: 1)
      .overlay {
        Color.clear.frame(width: 9).contentShape(Rectangle())
          .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
          }
          .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
              // A width remembered from a wider window starts the drag from what is shown.
              let origin = start ?? min(max(width, range.lowerBound), range.upperBound)
              start = origin
              width = min(max(origin - value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
              start = nil
              ended(width)
            })
      }
      .accessibilityHidden(true)
  }
}
