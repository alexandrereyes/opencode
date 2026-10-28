import OpenCodeKit
import SwiftUI

/// The comment of one quote, written in the message composer's own editor (`ComposerEditor` with
/// `ComposerComment`) over an ephemeral draft. Concluir is the only change to the message draft.
struct QuoteCommentEditor: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let quote: ChatQuote
  let store: ConversationStore
  let draft: ConversationDraft
  @State private var editor: ConversationDraft
  @State private var lent = false
  @State private var committed = false
  init(quote: ChatQuote, store: ConversationStore, draft: ConversationDraft) {
    self.quote = quote
    self.store = store
    self.draft = draft
    _editor = State(initialValue: draft.commentEditor(quote))
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          QuotedPassage(text: quote.text).textSelection(.enabled)
          ComposerEditor(
            store: store, draft: editor, expanded: false,
            comment: ComposerComment(
              placeholder: "Adicione um comentário…",
              reservedBytes: draft.attachments.filter { $0.quoteID != quote.id }.reduce(0) { $0 + $1.size },
              commit: commit)
          ) {}
          Button("Remover", systemImage: "trash", role: .destructive) {
            draft.removeQuote(quote)
            dismiss()
          }.foregroundStyle(theme.color(.error))
        }.padding(20)
      }.scrollDismissesKeyboard(.interactively).background(theme.color(.background))
        .navigationTitle("Comentário").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Concluir", action: commit).fontWeight(.semibold).disabled(editor.importing)
          }
        }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      .tint(theme.color(.primary))
      .task {
        guard !lent else { return }
        lent = true
        await draft.lend(quote, to: editor)
      }
      .onAppear { editor.focused = true }
      // A transcription lands in the comment, like the fullscreen review of the message composer.
      .onChange(of: editor.dictationReview) { _, review in
        guard review else { return }
        editor.dictationReview = false
        editor.focused = true
      }
      .onDisappear {
        guard !committed else { return }
        Task { try? await editor.discard() }
      }
  }
  private func commit() {
    guard !committed, !editor.importing else { return }
    committed = true
    editor.recording.suspend()
    Task {
      await draft.commit(quote, from: editor)
      try? await editor.discard()
    }
    dismiss()
  }
}
