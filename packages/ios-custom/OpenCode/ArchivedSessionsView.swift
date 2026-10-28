import OpenCodeKit
import SwiftUI

struct ArchivedSessionsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let store: SessionStore
  @State private var deleteCandidate: Session?
  /// The Mac's search field (⌘F); the iPhone lists every archived session.
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  private var sessions: [Session] {
    ArchivedSessionSearch.filter(store.archived, query: query,
      project: { session in store.projects.first { $0.id == session.projectID }?.name },
      path: { store.directoryLabel($0)?.path })
  }

  var body: some View {
    NavigationStack {
      List(sessions) { session in
        Button {
          dismiss()
          store.conversationPath.append(.init(id: session.id))
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(session.displayTitle).appFont(.heading).foregroundStyle(theme.color(.textStrong))
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            SessionDirectoryLine(label: store.directoryLabel(session))
          }
        }.listRowBackground(theme.color(.surface))
          .accessibilityIdentifier("archived-row-" + session.id)
          .listRowInsets(EdgeInsets(top: 14, leading: AppLayout.margin, bottom: 14, trailing: AppLayout.margin))
          .listRowSeparatorTint(theme.color(.border))
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
              Haptics.play(.warning)
              deleteCandidate = session
            } label: { Label("Excluir", systemImage: "trash") }
              .tint(theme.color(.error))
          }
          .contextMenu {
            Button("Excluir sessão", systemImage: "trash", role: .destructive) {
              Haptics.play(.warning)
              deleteCandidate = session
            }
          }
          .disabled(store.busy.contains(session.id))
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .navigationTitle("Arquivadas")
      .sessionDeleteConfirmation($deleteCandidate, store: store)
      .toastOverlay(store.toast)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } } }
      .overlay {
        if store.archived.isEmpty {
          ContentUnavailableView("Nenhuma sessão arquivada", systemImage: "archivebox")
            .foregroundStyle(theme.color(.textSecondary))
        } else if sessions.isEmpty {
          ContentUnavailableView.search(text: query).foregroundStyle(theme.color(.textSecondary))
        }
      }
      #if os(macOS)
      .safeAreaInset(edge: .top, spacing: 0) { searchField }
      #endif
    }
  }

  #if os(macOS)
  /// Title, project and path, ignoring case and accents; ⌘F focuses it and Esc clears it.
  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textSecondary))
      TextField("Buscar por título, projeto ou caminho", text: $query)
        .textFieldStyle(.plain).focused($searchFocused)
        .onExitCommand { query = "" }
        .accessibilityIdentifier("archived-search")
      if !query.isEmpty {
        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary)).help("Limpar busca")
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color(.border), lineWidth: 0.7) }
    .padding(.horizontal, AppLayout.margin).padding(.vertical, 8)
    .background(theme.color(.background))
    .background {
      Button("Buscar") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    .onAppear { searchFocused = true }
  }
  #endif
}
