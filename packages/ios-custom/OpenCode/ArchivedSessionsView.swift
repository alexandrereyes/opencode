import OpenCodeKit
import SwiftUI

struct ArchivedSessionsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let store: SessionStore
  @State private var deleteCandidate: Session?

  var body: some View {
    NavigationStack {
      List(store.archived) { session in
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
        }
      }
    }
  }
}
