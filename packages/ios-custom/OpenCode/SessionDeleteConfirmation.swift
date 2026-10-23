import OpenCodeKit
import SwiftUI

private struct SessionDeleteConfirmation: ViewModifier {
  @Binding var candidate: Session?
  let store: SessionStore

  func body(content: Content) -> some View {
    content.alert("Excluir sessão", isPresented: Binding(
      get: { candidate != nil }, set: { if !$0 { candidate = nil } }
    ), presenting: candidate) { session in
      Button("Cancelar", role: .cancel) { candidate = nil }
      Button("Excluir sessão", role: .destructive) {
        candidate = nil
        Task { await store.delete(session) }
      }
    } message: { session in
      Text(SessionDeletionPlan.confirmation(session.displayTitle))
    }
  }
}

extension View {
  func sessionDeleteConfirmation(_ candidate: Binding<Session?>, store: SessionStore) -> some View {
    modifier(SessionDeleteConfirmation(candidate: candidate, store: store))
  }
}
