import OpenCodeKit
import SwiftUI

struct ArchivedSessionsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: SessionStore

  var body: some View {
    NavigationStack {
      List(store.archived) { session in
        Button {
          dismiss()
          store.conversationPath.append(.init(id: session.id))
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(session.displayTitle).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
            SessionDirectoryLine(label: store.directoryLabel(session))
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
