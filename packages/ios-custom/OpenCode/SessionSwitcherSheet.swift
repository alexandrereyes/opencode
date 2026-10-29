import OpenCodeKit
import SwiftUI

/// The same chips, sections and rows as Sessões, with local filtering and a marked current session.
struct SessionSwitcherSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let sessions: SessionStore
  let current: String
  let choose: (String) -> Void
  let newSession: (SessionListFilter) -> Void
  @State private var filter: SessionListFilter
  @State private var collapse: SessionSectionCollapse
  @State private var presentation = SessionListPresentation()
  @State private var showProjects = false
  @State private var showArchived = false
  @State private var projectAction: PreferenceIntent?

  init(sessions: SessionStore, current: String, choose: @escaping (String) -> Void,
    newSession: @escaping (SessionListFilter) -> Void) {
    self.sessions = sessions
    self.current = current
    self.choose = choose
    self.newSession = newSession
    // Start broad, but include ordinary Chats, which the tab intentionally keeps out of Todas.
    let filter = SessionListFilter(project: sessions.rows.first { $0.id == current }?.chat == true
      ? SessionListFilter.chats : nil)
    _filter = State(initialValue: filter)
    let collapse = SessionSectionCollapse(rawValue: UserDefaults.standard.string(forKey: "OpenCodeSessionSections") ?? "")
      ?? SessionSectionCollapse()
    _collapse = State(initialValue: collapse)
  }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        List {
          Color.clear.frame(height: 0).listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden).accessibilityHidden(true).id("switcher-top")
          SessionColumnSections(collapse: $collapse, store: sessions,
            rows: filter.rows(sessions.rows, label: sessions.directoryLabel), scope: filter,
            presentation: presentation, open: { choose($0.id) },
            archived: filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sessions.archived.isEmpty
              ? { showArchived = true } : nil,
            current: current, identifierPrefix: "switcher-row-") { _, content in content }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden).background(theme.color(.background))
        .scrollEdgeEffectStyle(.hard, for: .top)
        .accessibilityIdentifier("session-switcher-list")
        .sessionListScrolling(presentation, store: sessions)
        .onAppear { proxy.scrollTo("switcher-top", anchor: .top) }
        .onChange(of: filter) { _, _ in
          // This target exists before and after filtering, including when no results match.
          proxy.scrollTo("switcher-top", anchor: .top)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          VStack(spacing: 10) {
            SessionColumnHeader(newSession: { newSession(filter) }, newSessionDisabled: sessions.preferences == nil,
              close: { dismiss() }, newSessionIdentifier: "switcher-new-session")
            SessionChips(store: sessions, selection: $filter) { _, intent in
              projectAction = intent
            } add: { showProjects = true }
            .padding(.horizontal, AppLayout.margin)
            HStack(spacing: 8) {
              Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.icon))
              TextField("Buscar sessão", text: $filter.query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("switcher-search")
              if !filter.query.isEmpty {
                Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                  .buttonStyle(.plain).accessibilityLabel("Limpar busca")
              }
            }
            .appFont(.secondary).padding(10).background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, AppLayout.margin)
          }
          .padding(.top, 8).padding(.bottom, 10).background(theme.color(.background))
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $showProjects) { AddProjectPicker(store: sessions) }
      .sheet(isPresented: $showArchived) { ArchivedSessionsView(store: sessions) }
      .confirmationDialog("Alterar filtro?", isPresented: Binding(
        get: { projectAction != nil }, set: { if !$0 { projectAction = nil } })) {
        Button("Confirmar") {
          guard let intent = projectAction else { return }
          projectAction = nil
          Task {
            await sessions.mutate(intent)
            if let id = filter.project, id != SessionListFilter.chats,
              !sessions.selectedProjects.contains(where: { $0.project.id == id }) { filter.project = nil }
          }
        }
        Button("Cancelar", role: .cancel) { projectAction = nil }
      }
    }
    .sessionRowTimeline()
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .tint(theme.color(.primary))
  }
}
