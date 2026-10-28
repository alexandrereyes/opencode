import OpenCodeKit
import SwiftUI

/// The main window: Sessões | chat in a split view, and Contexto beside the chat in the detail column, behind a
/// draggable hairline. Contexto hides with ⌥⌘I, Visualizar or the `…` menu; Sessões with ⌃⌘S.
struct MacWindow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime
  @State private var context: ContextColumnStore?
  @AppStorage("OpenCodeMacContextWidth") private var contextWidth = 520.0

  var body: some View {
    NavigationSplitView {
      MacSessionColumn(store: store, runtime: runtime)
        .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 480)
    } detail: {
      // Contexto shares the detail column with the chat instead of being an inspector: an inspector gets its
      // own, empty part of the title bar, while the approved window has one strip with `…` and Nova sessão
      // over Contexto.
      HStack(spacing: 0) {
        MacChatColumn(store: store, runtime: runtime, context: context)
          .frame(minWidth: 460, maxWidth: .infinity)
        if runtime.contextVisible {
          MacColumnDivider(width: $contextWidth)
          // Offered the room first, up to the dragged width; a narrower window shrinks it to 400 pt before the
          // chat goes below its 460, so the window's minimum stays the two minimums.
          inspector.frame(minWidth: 400, maxWidth: min(max(contextWidth, 400), 760)).layoutPriority(1)
        }
      }
    }
    .background(theme.color(.background))
    .toastOverlay(store.toast)
    .sessionAlertOverlay(modal: false)
    .environment(\.sessionAlerts, SessionAlertsContext(center: store.alerts, open: { id in
      store.alerts.openingSession()
      select(id)
    }))
    .sessionRowTimeline()
    // The event stream stays open while the window is visible, the app frontmost or not: on the Mac the chat is
    // read beside other apps. Only a hidden or minimized window (`background`) stops it.
    .task(id: scenePhase == .background) { if scenePhase != .background { await store.run() } }
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
    // Shared views (alerts, Arquivadas) open a session by pushing an iPhone route; here that selects it.
    .onChange(of: store.conversationPath.last?.id) { _, id in
      guard let id else { return }
      store.conversationPath = []
      select(id)
    }
    .onChange(of: store.rows.first?.id, initial: true) { _, _ in
      guard runtime.selection.sessionID == nil else { return }
      #if DEBUG
      if let id = MacFixture.value("-OpenCodeMacSession") {
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
      runtime.selection.sessionID = SessionSections.group(store.filtered, chats: store.chatsSelected, now: .now)
        .first?.rows.first?.id
    }
    #if DEBUG
    .task {
      if MacProxyLaunch.pane != nil, MacCapture.folder != nil { openWindow(id: MacProxyWindow.id) }
      await MacCapture.window(context: { context }, runtime: runtime, theme: theme)
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

  /// A child session selects its root and opens the child in the middle column.
  private func select(_ id: String) {
    if store.rows.contains(where: { $0.id == id }) {
      runtime.selection = MacSelection(sessionID: id)
      return
    }
    if let root = store.rows.first(where: { $0.memberIDs.contains(id) }) {
      runtime.selection = MacSelection(sessionID: root.id, childID: id)
      return
    }
    runtime.selection = MacSelection(sessionID: id)
  }
}

/// The hairline between the chat and Contexto; dragging it resizes Contexto.
private struct MacColumnDivider: View {
  @Environment(\.appTheme) private var theme
  @Binding var width: Double
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
              let origin = start ?? width
              start = origin
              width = min(max(origin - value.translation.width, 400), 760)
            }
            .onEnded { _ in start = nil })
      }
      .accessibilityHidden(true)
  }
}
