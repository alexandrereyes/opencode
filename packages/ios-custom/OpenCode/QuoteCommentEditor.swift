import OpenCodeKit
import SwiftUI

struct QuotedPassage: View {
  @Environment(\.appTheme) private var theme
  let text: String
  var body: some View {
    Text(text).font(.subheadline).foregroundStyle(theme.color(.textSecondary))
      .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
      .overlay(alignment: .leading) { Rectangle().fill(theme.color(.primary)).frame(width: 2) }
  }
}

struct DraftQuotesCard: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.conversationQuotes) private var quoteContext
  @Bindable var draft: ConversationDraft
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation { expanded.toggle() }
      } label: {
        HStack {
          Label("Citações · \(draft.quotes.count)", systemImage: "bubble.left")
          Spacer()
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
        }.appFont(.chrome).foregroundStyle(theme.color(.textSecondary)).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("draft-quotes")
      if expanded {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(draft.quotes.enumerated()), id: \.element.id) { index, quote in
              VStack(alignment: .leading, spacing: 8) {
                Text("Citação \(index + 1)").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                HStack(alignment: .top) {
                  QuotedPassage(text: quote.text).lineLimit(4)
                  Button("Editar citação", systemImage: "pencil") {
                    draft.focused = false
                    draft.commenting = quote
                  }.labelStyle(.iconOnly)
                  Button("Remover citação", systemImage: "xmark") {
                    draft.removeQuote(quote)
                  }.labelStyle(.iconOnly)
                }
                if !quote.comment.isEmpty {
                  Text(quote.comment).font(.subheadline).lineLimit(4).padding(.leading, 12)
                }
                Button("Ir ao trecho citado", systemImage: "text.quote") { quoteContext.source?(quote) }
                  .appFont(.caption).buttonStyle(.plain)
                ForEach(draft.attachments.filter { $0.quoteID == quote.id }) { attachment in
                  Label(
                    attachment.name,
                    systemImage: attachment.mime.hasPrefix("image/") ? "photo" : "doc"
                  )
                  .font(.caption).foregroundStyle(theme.color(.textSecondary)).padding(.leading, 12)
                }
              }
            }
          }
        }.frame(maxHeight: 210).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(14).foregroundStyle(theme.color(.text))
      .background(theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16).strokeBorder(theme.color(.border), lineWidth: 0.7)
      }
      .disabled(draft.sending || draft.importing)
  }
}

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
        draft.lend(quote, to: editor)
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
