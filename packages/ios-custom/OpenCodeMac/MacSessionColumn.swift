import AppKit
import OpenCodeKit
import SwiftUI

/// The Mac host of the shared Sessões column (`OpenCode/SessionColumn/`): selection instead of a push, the
/// iPhone's swipe and long-press actions as a right-click menu, the selection mode (⌘-click or Selecionar) with
/// its batch actions in the column's title bar, and the Sessão mestra accessory at the bottom, like the iPhone's
/// tab accessory.
struct MacSessionColumn: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: SessionStore
  @Bindable var runtime: MacWindowRuntime
  @State private var renameCandidate: SessionRow?
  @State private var renameText = ""
  @State private var deleteCandidate: Session?
  @State private var projectAction: ProjectAction?
  @State private var showArchived = false
  @State private var showProjects = false
  @State private var bulkDelete: [SessionRow]?
  @State private var bulkArchive: [SessionRow]?
  @AppStorage("OpenCodeSessionSections") private var collapse = SessionSectionCollapse()
  /// Holds the rows' order and sections still while the list scrolls, like the iPhone's Sessões.
  @State private var presentation = SessionListPresentation()

  private struct ProjectAction: Identifiable {
    let name: String
    let intent: PreferenceIntent
    var id: String { name }
    var removes: Bool { if case .close = intent { true } else { false } }
  }

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("MacSessionColumn")
    #endif
    HStack(spacing: 0) {
      MacProjectRail(store: store) { name, intent in
        projectAction = ProjectAction(name: name, intent: intent)
      } add: { showProjects = true } shortcuts: { runtime.shortcutsVisible = true } shownOrder: { order in
        if runtime.railOrder != order { runtime.railOrder = order }
      }
      sessionList
    }
  }

  private var sessionList: some View {
    List {
      MacQuotaRings(quota: store.quota, runtime: runtime)
      .padding(.horizontal, AppLayout.margin)
      .padding(.top, 10).padding(.bottom, 6)
      .macThinScrollers()
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(theme.color(.background))
      if let error = store.error {
        HStack(alignment: .top) {
          Image(systemName: "wifi.exclamationmark")
          Text(error).appFont(.caption)
          Spacer()
          Button("Tentar novamente") { Task { await store.reload() } }.appFont(.caption)
        }
        .foregroundStyle(theme.color(.error))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.color(.background))
      }
      SessionColumnSections(
        collapse: $collapse, store: store, rows: store.filtered,
        scope: SessionListFilter(project: store.selectedProject, state: store.filter), presentation: presentation,
        open: open,
        archived: { showArchived = true },
        selection: runtime.sessionSelection,
        toggle: { row in
          guard !store.busy.contains(SessionStore.bulkKey) else { return }
          withAnimation(.snappy(duration: 0.2)) { runtime.sessionSelection.toggle(row.id) }
        }
      ) { row, content in
        #if DEBUG
        let _ = MacPerf.count("SessionRow")
        #endif
        MacSessionRowCell(store: store, runtime: runtime, row: row, content: content) { rowActions(row) }
      }
    }
    .listStyle(.plain)
    .sessionListScrolling(presentation, store: store)
    .environment(\.defaultMinListRowHeight, 1)
    .scrollContentBackground(.hidden)
    .background(theme.color(.background))
    .safeAreaInset(edge: .bottom, spacing: 0) { MacMasterAccessory(store: store, runtime: runtime) }
    // The approved title bar has no sidebar button: Sessões collapses with ⌃⌘S and Visualizar.
    .toolbar(removing: .sidebarToggle)
    // Voice and Nova sessão at the column's right edge, like Mail's and Notes' sidebar items; they hide with the
    // column (⌘N and Nova sessão at the bar's end and the menus still reach them). Ajustes is at the rail's foot.
    .toolbar {
      MacToolbarFlexibleSpace()
      MacPlainToolbarItem {
        if let selection = selectionActions {
          selectionTools(selection)
        } else {
          columnTools
        }
      }
    }
    .alert("Renomear sessão", isPresented: Binding(
      get: { renameCandidate != nil }, set: { if !$0 { renameCandidate = nil } })
    ) {
      TextField("Título", text: $renameText)
      Button("Cancelar", role: .cancel) { renameCandidate = nil }
      Button("Salvar") {
        if let row = renameCandidate { Task { await store.rename(row, title: renameText) } }
        renameCandidate = nil
      }
    }
    .sessionDeleteConfirmation($deleteCandidate, store: store)
    .alert(
      SessionBulkCopy.deleteTitle(bulkDelete?.count ?? 0),
      isPresented: Binding(get: { bulkDelete != nil }, set: { if !$0 { bulkDelete = nil } }),
      presenting: bulkDelete
    ) { rows in
      Button("Cancelar", role: .cancel) { bulkDelete = nil }
      Button("Arquivar") {
        bulkDelete = nil
        archiveSelection(rows)
      }
      Button(SessionBulkCopy.deleteTitle(rows.count), role: .destructive) {
        bulkDelete = nil
        Task { runtime.sessionSelection.complete(await store.deleteMany(rows.map(\.session))) }
      }
    } message: { rows in
      Text(SessionBulkCopy.deleteMessage(
        count: rows.count, running: rows.filter { !$0.memberIDs.isDisjoint(with: store.active) }.count,
        master: rows.contains { $0.session.agent == "mestra" }))
    }
    .confirmationDialog(
      bulkArchive?.count == 1 ? "Arquivar 1 sessão?" : "Arquivar \(bulkArchive?.count ?? 0) sessões?",
      isPresented: Binding(get: { bulkArchive != nil }, set: { if !$0 { bulkArchive = nil } }),
      presenting: bulkArchive
    ) { rows in
      Button("Arquivar", role: .destructive) {
        bulkArchive = nil
        archiveSelection(rows)
      }
      Button("Cancelar", role: .cancel) { bulkArchive = nil }
    } message: { _ in
      Text("As sessões sairão de Recentes e ficarão na lista de arquivadas. Não há opção de desarquivar nesta versão.")
    }
    .confirmationDialog(
      projectAction?.removes == true
        ? "Remover dos filtros?" : projectAction?.name == "Chats" ? "Reordenar Chats?" : "Reordenar repositório?",
      isPresented: Binding(get: { projectAction != nil }, set: { if !$0 { projectAction = nil } })
    ) {
      if let action = projectAction {
        Button(action.removes ? "Remover dos filtros" : "Confirmar nova posição",
          role: action.removes ? .destructive : nil) {
          Task { await store.mutate(action.intent) }
          projectAction = nil
        }
      }
      Button("Cancelar", role: .cancel) { projectAction = nil }
    } message: {
      Text(projectAction?.name == "Chats"
        ? "Isso altera apenas a ordem dos filtros."
        : "Isso altera apenas os filtros. O repositório e suas sessões não serão excluídos.")
    }
    #if DEBUG
    .task {
      guard MacAjustesChecks.mode == "archived" else { return }
      try? await Task.sleep(for: .seconds(2))
      showArchived = true
    }
    #endif
    .sheet(isPresented: $showArchived) {
      ArchivedSessionsView(store: store).frame(minWidth: 460, minHeight: 520).macCancelable()
    }
    .sheet(isPresented: $showProjects) { AddProjectPicker(store: store).macCancelable() }
    // Like the web and the iPhone, changing the view ends the selection; hidden or removed rows leave it.
    .onChange(of: store.filter) { runtime.sessionSelection.clear() }
    .onChange(of: store.selectedProject) { runtime.sessionSelection.clear() }
    .onChange(of: visibleIDs) { _, visible in runtime.sessionSelection.retain(Set(visible)) }
    .onChange(of: runtime.bulkRequest) { _, request in
      guard let request else { return }
      runtime.bulkRequest = nil
      switch request {
      case .selectAll: selectionActions?.selectAll()
      // From the menu or ⌥⌘⌫ it confirms first, like one session's Arquivar…; the bar's button archives at once.
      case .archive: if !selectedRows.isEmpty { bulkArchive = selectedRows }
      case .delete: selectionActions?.delete()
      }
    }
  }

  /// A click opens the session; ⌘-click starts or extends the selection, like Finder's lists.
  private func open(_ row: SessionRow) {
    if NSEvent.modifierFlags.contains(.option) {
      openWindow(id: "main", value: MacWindowTarget(sessionID: row.id))
      return
    }
    if NSEvent.modifierFlags.contains(.command) {
      withAnimation(.snappy(duration: 0.2)) {
        if runtime.sessionSelection.active {
          runtime.sessionSelection.toggle(row.id)
        } else {
          runtime.sessionSelection.start(row.id)
        }
      }
      return
    }
    runtime.selection = MacSelection(sessionID: row.id)
  }

  private var columnTools: some View {
    HStack(spacing: 4) {
      Button { runtime.voicePresentation.toggle(runtime.app.audio.voice, sessions: store) } label: {
        MacToolbarIcon(symbol: "waveform", role: runtime.voicePresentation.visible(runtime.app.audio.voice) ? .primary : .text)
      }
        .disabled(runtime.app.audio.voice.busy)
        .help(runtime.voicePresentation.visible(runtime.app.audio.voice) ? "Encerrar conversa por voz" : "Conversar por voz com a Sessão mestra")
        .accessibilityLabel("Conversar por voz")
      Button { runtime.newSession() } label: { MacToolbarIcon(symbol: "square.and.pencil") }
        .disabled(store.preferences == nil)
        .help("Nova sessão (⌘N)")
        .accessibilityLabel("Nova sessão")
    }
    .buttonStyle(.plain)
  }

  /// While selecting, the column's title bar holds the batch actions in place of voice and Nova sessão, so they stay
  /// in view however far the list is scrolled.
  private func selectionTools(_ selection: SessionColumnSelection) -> some View {
    HStack(spacing: 4) {
      if selection.working { ProgressView().controlSize(.small).padding(.trailing, 4) }
      Text(selection.count == 1 ? "1 selecionada" : "\(selection.count) selecionadas")
        .appFont(.caption).foregroundStyle(theme.color(.textSecondary)).monospacedDigit()
        .padding(.trailing, 4)
      Button(action: selection.selectAll) { MacToolbarIcon(symbol: "checklist") }
        .disabled(!selection.canSelectAll)
        .help("Selecionar todas (⌥⌘A)")
        .accessibilityLabel("Selecionar todas")
      Button(action: selection.archive) { MacToolbarIcon(symbol: "archivebox") }
        .disabled(selection.count == 0)
        .help("Arquivar (\(selection.count))")
        .accessibilityLabel("Arquivar")
      Button(action: selection.delete) { MacToolbarIcon(symbol: "trash", role: .error) }
        .disabled(selection.count == 0)
        .help("Excluir (\(selection.count)) (⌘⌫)")
        .accessibilityLabel("Excluir")
      Button(action: selection.cancel) { MacToolbarIcon(symbol: "xmark") }
        .help("Concluir a seleção")
        .accessibilityLabel("Concluir a seleção")
    }
    .buttonStyle(.plain)
    .disabled(selection.working)
  }

  /// Rows of the expanded sections, in display order; "Selecionar todas" and the selection use only these.
  private var visibleIDs: [String] {
    SessionSections.group(store.filtered, now: .now)
      .filter { !collapse.collapsed($0.kind) }.flatMap(\.rows).map(\.id)
  }

  private var selectedRows: [SessionRow] {
    let rows = Dictionary(store.filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return runtime.sessionSelection.ids.compactMap { rows[$0] }
  }

  private var selectionActions: SessionColumnSelection? {
    guard runtime.sessionSelection.active else { return nil }
    let visible = visibleIDs
    return SessionColumnSelection(
      count: runtime.sessionSelection.ids.count,
      canSelectAll: visible.contains { !runtime.sessionSelection.contains($0) },
      working: store.busy.contains(SessionStore.bulkKey),
      archive: { archiveSelection(selectedRows) },
      delete: { bulkDelete = selectedRows },
      selectAll: { withAnimation(.snappy(duration: 0.2)) { runtime.sessionSelection.selectAll(visible) } },
      cancel: { withAnimation(.snappy(duration: 0.2)) { runtime.sessionSelection.clear() } })
  }

  /// No confirmation and no undo, like the iPhone: the backend has no unarchive, and the rows stay in Arquivadas.
  private func archiveSelection(_ rows: [SessionRow]) {
    Task { runtime.sessionSelection.complete(await store.archiveMany(rows.map(\.id))) }
  }

  @ViewBuilder private func rowActions(_ row: SessionRow) -> some View {
    Button("Abrir sessão", systemImage: "bubble.left") { runtime.selection = MacSelection(sessionID: row.id) }
    Button("Abrir em nova janela", systemImage: "macwindow.badge.plus") {
      openWindow(id: "main", value: MacWindowTarget(sessionID: row.id))
    }
    Button("Selecionar", systemImage: "checkmark.circle") {
      withAnimation(.snappy(duration: 0.2)) { runtime.sessionSelection.start(row.id) }
    }
    Button("Nova sessão a partir desta", systemImage: "square.and.pencil") { runtime.newSession(from: row.id) }
    Divider()
    Button("Renomear…", systemImage: "pencil") {
      renameText = row.session.title ?? ""
      renameCandidate = row
    }
    Button(row.pinned ? "Desafixar" : "Fixar", systemImage: row.pinned ? "pin.slash" : "pin") {
      Task { await store.pin(row) }
    }
    Button(row.notify ? "Não avisar ao terminar" : "Avisar ao terminar", systemImage: row.notify ? "bell.slash" : "bell") {
      Task { await store.toggleNotify(row) }
    }
    if row.unread {
      Button("Marcar como lida", systemImage: "envelope.open") { Task { await store.markRead(row.session) } }
    }
    Divider()
    Button("Arquivar…", systemImage: "archivebox") { runtime.archiveRequest = row }
    Button("Excluir sessão…", systemImage: "trash", role: .destructive) { deleteCandidate = row.session }
  }
}

/// A row of Sessões with its highlight, right-click menu and opened subagents. The List builds this value for every
/// row whenever the rows change; its body, and what it reads, run only for the rows on screen.
private struct MacSessionRowCell<Menu: View>: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacWindowRuntime
  let row: SessionRow
  let content: SessionColumnRow
  @ViewBuilder let menu: () -> Menu

  var body: some View {
    VStack(spacing: 0) {
      content
        .background {
          if !runtime.sessionSelection.active && runtime.selection.sessionID == row.id {
            RoundedRectangle(cornerRadius: 12).fill(theme.color(.highlight)).padding(-7)
          }
        }
        // The hairline between rows ends with the row's text, like the mock, not at the column's edge.
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        .contextMenu { if !runtime.sessionSelection.active { menu() } }
        .disabled(store.busy.contains(row.id))
      if !runtime.sessionSelection.active {
        MacSubagentTree(store: store, runtime: runtime, rootID: row.id)
      }
    }
  }
}

/// The LLM proxy rings atop Sessões. Built here, from references only, so a list change re-evaluating the column
/// does not rebuild them: a new `open` closure would, and each ring projects every account's quota.
private struct MacQuotaRings: View {
  let quota: SubscriptionStore
  let runtime: MacWindowRuntime

  var body: some View {
    SessionQuotaRings(quota: quota) { provider in runtime.showProxy(.provider(provider)) }
  }
}

/// The iPhone's "Sessão mestra" tab accessory at the foot of Sessões: the current master opens in the middle
/// column; without one, Nova sessão opens in its master mode and the first message creates it.
private struct MacMasterAccessory: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacWindowRuntime
  @State private var hovering = false

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("MacMasterAccessory")
    #endif
    Button { runtime.openMaster() } label: {
      HStack(spacing: 8) {
        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 13, weight: .medium))
          .foregroundStyle(theme.color(.accent))
        Text("Sessão mestra").fontWeight(.medium).foregroundStyle(theme.color(.textStrong))
        Spacer(minLength: 4)
        Text(store.masterAvailability == .available
          ? (store.requestCount > 0 ? "\(store.requestCount) precisam de você" : "Tudo em dia")
          : store.masterAvailability.label)
          .foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(theme.color(.icon))
      }
      .appFont(.caption).monospacedDigit()
      .padding(.horizontal, 12).frame(minHeight: 36)
      .background(theme.color(runtime.selection.master ? .highlight : .surface).opacity(hovering ? 0.9 : 1),
        in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .disabled(store.masterAvailability != .available)
    .help("Sessão mestra (⇧⌘M)")
    .padding(.horizontal, 8).padding(.vertical, 10)
    .background(theme.color(.background))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}
