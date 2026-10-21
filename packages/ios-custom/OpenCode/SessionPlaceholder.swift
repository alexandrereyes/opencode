import OpenCodeKit
import SwiftUI

struct SessionPlaceholder: View {
  @Environment(\.appTheme) private var theme
  let session: Session
  let store: SessionStore

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      if let row = store.rows.first(where: { $0.id == session.id }) {
        HStack(spacing: 12) {
          SessionAvatar(row: row, size: 48)
          VStack(alignment: .leading, spacing: 4) {
            Text(row.projectName).font(.headline).foregroundStyle(theme.color(.textStrong))
            Text(store.branch(session)).font(.subheadline).foregroundStyle(
              theme.color(.textSecondary))
          }
        }
        Label(
          stateLabel(row.state), systemImage: row.state == .running ? "waveform" : "bubble.left"
        )
        .foregroundStyle(
          theme.color(
            row.state == .running
              ? .success
              : row.state == .permission
                ? .error : row.state == .question ? .info : .textSecondary))
      } else {
        Text(store.projects.first { $0.id == session.projectID }?.displayName ?? "Repositório")
          .font(.headline).foregroundStyle(theme.color(.textStrong))
        Text(store.branch(session)).font(.subheadline).foregroundStyle(theme.color(.textSecondary))
        Label("Arquivada", systemImage: "archivebox").foregroundStyle(theme.color(.textSecondary))
      }
      Text(
        "A tela da sessão está em construção. Em breve, você poderá acompanhar a conversa e responder por aqui."
      )
      .font(.body).foregroundStyle(theme.color(.textSecondary))
      Spacer()
    }
    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.background))
    .navigationTitle(session.displayTitle).navigationBarTitleDisplayMode(.inline)
    .task { await store.markRead(session) }
  }

  private func stateLabel(_ state: SessionState) -> String {
    switch state {
    case .permission: "Aguardando permissão"
    case .question: "Aguardando sua resposta"
    case .running: "Trabalhando"
    case .unread: "Nova atividade"
    case .stopped: "Parada"
    }
  }
}

struct ArchivedSessionsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: SessionStore

  var body: some View {
    NavigationStack {
      List(store.archived) { session in
        NavigationLink {
          SessionPlaceholder(session: session, store: store)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(session.displayTitle).foregroundStyle(theme.color(.textStrong))
            Text(store.branch(session)).font(.caption).foregroundStyle(theme.color(.textSecondary))
          }
        }.listRowBackground(theme.color(.surface))
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .navigationTitle("Arquivadas")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluir") { dismiss() } } }
      .overlay {
        if store.archived.isEmpty {
          ContentUnavailableView("Nenhuma sessão arquivada", systemImage: "archivebox")
            .foregroundStyle(theme.color(.textSecondary))
        }
      }
    }
  }
}
