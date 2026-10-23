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
        }.font(.subheadline).foregroundStyle(theme.color(.textSecondary)).contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityIdentifier("draft-quotes")
      if expanded {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(draft.quotes) { quote in
              VStack(alignment: .leading, spacing: 8) {
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

struct QuoteCommentEditor: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let quote: ChatQuote
  let store: ConversationStore
  let draft: ConversationDraft
  @State private var editor: ConversationDraft
  @State private var owner = UUID()
  init(quote: ChatQuote, store: ConversationStore, draft: ConversationDraft) {
    self.quote = quote
    self.store = store
    self.draft = draft
    // This editor never loads or persists: Concluir is the only draft mutation.
    let editor = ConversationDraft(server: "local", id: quote.id)
    editor.text = quote.document.attributed
    editor.selection = NSRange(location: editor.editorText.length, length: 0)
    _editor = State(initialValue: editor)
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          QuotedPassage(text: quote.text).textSelection(.enabled)
          if let trigger = editor.trigger, trigger.character != "/" {
            ComposerSuggestions(store: store, trigger: trigger) { item in
              editor.insert(item.token, replacing: trigger.range)
            }
          }
          ComposerTextView(
            draft: editor, theme: theme, expanded: false, owner: owner, label: "Comentário",
            identifier: "comment-composer"
          )
          .overlay(alignment: .topLeading) {
            if editor.isEmpty {
              Text("Adicione um comentário sobre este trecho…").foregroundStyle(
                theme.color(.textSecondary)
              )
              .allowsHitTesting(false)
            }
          }
          .padding(12).frame(minHeight: 100, alignment: .top)
          .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 12))
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
            Button("Concluir") {
              var value = quote
              value.document = editor.document
              if let index = draft.quotes.firstIndex(where: { $0.id == quote.id }) {
                draft.quotes[index] = value
              } else {
                draft.quotes.append(value)
              }
              dismiss()
            }.fontWeight(.semibold)
          }
        }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      .tint(theme.color(.primary)).onAppear {
        editor.editorOwner = owner
        editor.focused = true
      }
  }
}
