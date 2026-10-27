import AppKit
import OpenCodeKit
import SwiftUI

/// The Mac host of the shared Sessões column (`OpenCode/SessionColumn/`): selection instead of a push, the
/// iPhone's swipe and long-press actions as a right-click menu, and Configurações in the header.
struct MacSessionColumn: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime
  @State private var renameCandidate: SessionRow?
  @State private var renameText = ""
  @State private var archiveCandidate: SessionRow?
  @State private var deleteCandidate: Session?
  @State private var projectAction: ProjectAction?
  @State private var showArchived = false
  @State private var showProjects = false
  @State private var showNewSession = false

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
        open: { runtime.selection = MacSelection(sessionID: $0.id) },
        archived: { showArchived = true }
      ) { row, content in
        content
          .background {
            if runtime.selection.sessionID == row.id {
              RoundedRectangle(cornerRadius: 12).fill(theme.color(.highlight)).padding(-7)
            }
          }
          // The hairline between rows ends with the row's text, like the mock, not at the column's edge.
          .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
          .contextMenu { rowActions(row) }
          .disabled(store.busy.contains(row.id))
      }
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
    .scrollContentBackground(.hidden)
    .background(theme.color(.background))
    // The approved title bar has no sidebar button: Sessões collapses with ⌃⌘S and Visualizar.
    .toolbar(removing: .sidebarToggle)
    .toolbar {
      // Voice calls stay on the iPhone in this Mac version: the button is shown disabled.
      MacPlainToolbarItem {
        HStack(spacing: 4) {
          Button {} label: { MacToolbarIcon(symbol: "waveform") }
            .disabled(true)
            .help("Conversa por voz (em breve no Mac)")
            .accessibilityLabel("Conversar por voz")
          Button { openSettings() } label: { MacToolbarIcon(symbol: "gearshape") }
            .help("Configurações (⌘,)")
            .accessibilityLabel("Configurações")
          Button { showNewSession = true } label: { MacToolbarIcon(symbol: "square.and.pencil") }
            .disabled(store.preferences == nil)
            .help("Nova sessão")
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
    .confirmationDialog(
      "Arquivar sessão?",
      isPresented: Binding(get: { archiveCandidate != nil }, set: { if !$0 { archiveCandidate = nil } })
    ) {
      if let row = archiveCandidate {
        Button("Arquivar", role: .destructive) {
          Task { await store.archive(row) }
          archiveCandidate = nil
        }
      }
      Button("Cancelar", role: .cancel) { archiveCandidate = nil }
    } message: {
      Text("A sessão sairá de Recentes e ficará na lista de arquivadas. Não há opção de desarquivar nesta versão.")
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
    }
    .sheet(isPresented: $showArchived) {
      ArchivedSessionsView(store: store).frame(minWidth: 460, minHeight: 520)
    }
    .sheet(isPresented: $showProjects) { MacAddProject(store: store) }
    .sheet(isPresented: $showNewSession) { MacNewSession(store: store, runtime: runtime) }
    .onReceive(NotificationCenter.default.publisher(for: .macNewSession)) { _ in showNewSession = true }
  }

  @ViewBuilder private func rowActions(_ row: SessionRow) -> some View {
    Button("Abrir sessão", systemImage: "bubble.left") { runtime.selection = MacSelection(sessionID: row.id) }
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
    Button("Arquivar…", systemImage: "archivebox") { archiveCandidate = row }
    Button("Excluir sessão…", systemImage: "trash", role: .destructive) { deleteCandidate = row.session }
  }
}

/// Adds a repository to the filter chips. The server must reach the folder; on this Mac the folder picker
/// fills the path.
private struct MacAddProject: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.appTheme) private var theme
  let store: SessionStore
  @State private var path = ""
  @State private var error: String?
  @State private var working = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Adicionar repositório").font(.title3.bold())
      Text("Informe a pasta no servidor. Ela passa a aparecer como filtro nas Sessões.")
        .foregroundStyle(theme.color(.textSecondary))
      HStack {
        TextField("/Users/…/repositorio", text: $path).textFieldStyle(.roundedBorder)
        Button("Escolher…") {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          if panel.runModal() == .OK, let url = panel.url { path = url.path }
        }
      }
      if let error { Text(error).foregroundStyle(theme.color(.error)).font(.caption) }
      HStack {
        Spacer()
        Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Adicionar") {
          working = true
          Task {
            do {
              _ = try await store.addProject(directory: path.trimmingCharacters(in: .whitespaces))
              dismiss()
            } catch { self.error = error.localizedDescription }
            working = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || working)
      }
    }
    .padding(20).frame(width: 520)
  }
}
