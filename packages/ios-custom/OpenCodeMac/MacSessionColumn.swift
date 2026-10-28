import AppKit
import OpenCodeKit
import SwiftUI

/// The Mac host of the shared Sessões column (`OpenCode/SessionColumn/`): selection instead of a push, the
/// iPhone's swipe and long-press actions as a right-click menu, the selection mode (⌘-click or Selecionar) with
/// its batch actions, and the Sessão mestra accessory at the bottom, like the iPhone's tab accessory.
struct MacSessionColumn: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime
  @State private var renameCandidate: SessionRow?
  @State private var renameText = ""
  @State private var deleteCandidate: Session?
  @State private var projectAction: ProjectAction?
  @State private var showArchived = false
  @State private var showProjects = false
  @State private var bulkDelete: [SessionRow]?
  @AppStorage("OpenCodeSessionSections") private var collapse = SessionSectionCollapse()

  private struct ProjectAction: Identifiable {
    let name: String
    let intent: PreferenceIntent
    var id: String { name }
    var removes: Bool { if case .close = intent { true } else { false } }
  }

  var body: some View {
    List {
      VStack(spacing: 14) {
        SessionQuotaRings(quota: store.quota) { provider in
          runtime.proxyPane = .provider(provider)
          openWindow(id: MacProxyWindow.id)
        }
        SessionChips(store: store) { name, intent in
          projectAction = ProjectAction(name: name, intent: intent)
        } add: {
          showProjects = true
        }
        if let selection = selectionActions { selectionBar(selection) }
      }
      .padding(.horizontal, AppLayout.margin)
      .padding(.top, 10).padding(.bottom, 6)
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
        store: store,
        open: open,
        archived: { showArchived = true },
        selection: runtime.sessionSelection,
        toggle: { row in
          guard !store.busy.contains(SessionStore.bulkKey) else { return }
          withAnimation(.snappy(duration: 0.2)) { runtime.sessionSelection.toggle(row.id) }
        }
      ) { row, content in
        content
          .background {
            if !runtime.sessionSelection.active && runtime.selection.sessionID == row.id {
              RoundedRectangle(cornerRadius: 12).fill(theme.color(.highlight)).padding(-7)
            }
          }
          // The hairline between rows ends with the row's text, like the mock, not at the column's edge.
          .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
          .contextMenu { if !runtime.sessionSelection.active { rowActions(row) } }
          .disabled(store.busy.contains(row.id))
      }
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
    .scrollContentBackground(.hidden)
    .background(theme.color(.background))
    .safeAreaInset(edge: .bottom, spacing: 0) { MacMasterAccessory(store: store, runtime: runtime) }
    // The approved title bar has no sidebar button: Sessões collapses with ⌃⌘S and Visualizar.
    .toolbar(removing: .sidebarToggle)
    .toolbar {
      // Voice calls stay on the iPhone in this Mac version: the button is shown disabled.
      MacPlainToolbarItem {
        HStack(spacing: 4) {
          Button {} label: { MacToolbarIcon(symbol: "waveform") }
            .disabled(true)
            .help("Conversa por voz (só no iPhone por enquanto)")
            .accessibilityLabel("Conversar por voz")
          Button { openSettings() } label: { MacToolbarIcon(symbol: "gearshape") }
            .help("Configurações (⌘,)")
            .accessibilityLabel("Configurações")
          Button { runtime.newSession() } label: { MacToolbarIcon(symbol: "square.and.pencil") }
            .disabled(store.preferences == nil)
            .help("Nova sessão (⌘N)")
            .accessibilityLabel("Nova sessão")
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
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
    .sheet(isPresented: $showArchived) {
      ArchivedSessionsView(store: store).frame(minWidth: 460, minHeight: 520)
    }
    .sheet(isPresented: $showProjects) { AddProjectPicker(store: store) }
    // Like the web and the iPhone, changing the view ends the selection; hidden or removed rows leave it.
    .onChange(of: store.filter) { runtime.sessionSelection.clear() }
    .onChange(of: store.selectedProject) { runtime.sessionSelection.clear() }
    .onChange(of: visibleIDs) { _, visible in runtime.sessionSelection.retain(Set(visible)) }
    .onChange(of: runtime.bulkRequest) { _, request in
      guard let request else { return }
      runtime.bulkRequest = nil
      switch request {
      case .selectAll: selectionActions?.selectAll()
      case .archive: selectionActions?.archive()
      case .delete: selectionActions?.delete()
      }
    }
  }

  /// A click opens the session; ⌘-click starts or extends the selection, like Finder's lists.
  private func open(_ row: SessionRow) {
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

  /// `N selecionadas · Selecionar todas · OK`, then Arquivar (N) and Excluir (N) as plain links.
  private func selectionBar(_ selection: SessionColumnSelection) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      SessionSelectionBar(selection: selection)
      HStack(spacing: 14) {
        Button("Arquivar (\(selection.count))", systemImage: "archivebox", action: selection.archive)
        Button("Excluir (\(selection.count))", systemImage: "trash", role: .destructive, action: selection.delete)
          .foregroundStyle(theme.color(.error))
        Spacer(minLength: 0)
        if selection.working { ProgressView().controlSize(.small) }
      }
      .appFont(.caption)
      .buttonStyle(.plain)
      .foregroundStyle(theme.color(.text))
      .disabled(selection.working)
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 10))
    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  /// Rows of the expanded sections, in display order; "Selecionar todas" and the selection use only these.
  private var visibleIDs: [String] {
    SessionSections.group(store.filtered, chats: store.chatsSelected, now: .now)
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
    Button(row.muted ? "Reativar" : "Silenciar", systemImage: row.muted ? "bell" : "bell.slash") {
      Task { await store.mute(row) }
    }
    if row.unread {
      Button("Marcar como lida", systemImage: "envelope.open") { Task { await store.markRead(row.session) } }
    }
    Divider()
    Button("Arquivar…", systemImage: "archivebox") { runtime.archiveRequest = row }
    Button("Excluir sessão…", systemImage: "trash", role: .destructive) { deleteCandidate = row.session }
  }
}

/// The iPhone's "Sessão mestra" tab accessory at the foot of Sessões: the current master opens in the middle
/// column; without one, Nova sessão opens in its master mode and the first message creates it.
private struct MacMasterAccessory: View {
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  let runtime: MacRuntime
  @State private var hovering = false

  var body: some View {
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
    .padding(.horizontal, AppLayout.margin - 4).padding(.vertical, 10)
    .background(theme.color(.background))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}
