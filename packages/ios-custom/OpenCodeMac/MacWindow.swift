import OpenCodeKit
import SwiftUI

/// The main window: Sessões | chat in a split view, and Contexto as the inspector on the right. An inspector is
/// the Mac's collapsible trailing column; a three-column split view cannot hide its last column.
struct MacWindow: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime
  @State private var context: ContextColumnStore?

  var body: some View {
    navigation
    .inspector(isPresented: $runtime.contextVisible) {
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
      .inspectorColumnWidth(min: 400, ideal: 540, max: 760)
      .toolbar {
        ToolbarItem {
          Button { runtime.contextVisible.toggle() } label: { Label("Contexto", systemImage: "sidebar.right") }
            .help("Ocultar contexto (⌥⌘I)")
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
    .task(id: scenePhase == .active) { if scenePhase == .active { await store.run() } }
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
    #endif
  }

  private var navigation: some View {
    NavigationSplitView {
      MacSessionColumn(store: store, runtime: runtime)
        .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 480)
    } detail: {
      // No minimum width here: a detail minimum beside an inspector makes AppKit's constraint pass loop.
      MacChatColumn(store: store, runtime: runtime, context: context)
    }
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
