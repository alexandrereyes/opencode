import OpenCodeKit
import SwiftUI

struct ConversationQuoteContext {
  var index = ChatQuoteIndex()
  var pending: [ChatQuote] = []
  var dismissed: Set<String> = []
  var revealing: String?
  /// The user message reached through "Ir à mensagem com o comentário"; its folded bubble expands.
  var revealedMessage: String?
  var open: ((ChatQuoteMark) -> Void)?
  var source: ((ChatQuote) -> Void)?
  var target: String?
  var active: String?
  var align: ((String, String, Double) -> Void)?
}

struct ResponseQuoteHighlight: Equatable {
  let mark: ChatQuoteMark
  let ranges: [NSRange]
  var badge = true
}

struct ResponseQuoteContext {
  var highlights: [ResponseQuoteHighlight] = []
  var open: ((ChatQuoteMark) -> Void)?
  var target: String?
  var active: String?
  var align: ((String, String, Double) -> Void)?
}

// Handlers capture the conversation's state storage, so each body's copy behaves the same: comparing only
// the rendered data keeps every visible response from re-rendering whenever the conversation updates.
extension ConversationQuoteContext: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.index == rhs.index && lhs.pending == rhs.pending && lhs.dismissed == rhs.dismissed
      && lhs.revealing == rhs.revealing && lhs.revealedMessage == rhs.revealedMessage
      && lhs.target == rhs.target && lhs.active == rhs.active
  }
}
extension ResponseQuoteContext: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.highlights == rhs.highlights && lhs.target == rhs.target && lhs.active == rhs.active
  }
}

extension EnvironmentValues {
  @Entry var conversationQuotes = ConversationQuoteContext()
  @Entry var responseQuotes = ResponseQuoteContext()
}

struct QuoteDetailsSheet: View {
  @Environment(\.appTheme) private var theme
  let mark: ChatQuoteMark
  let edit: () -> Void
  let remove: () -> Void
  let source: () -> Void
  let message: () -> Void
  let close: () -> Void
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          QuotedPassage(text: mark.quote.text).textSelection(.enabled)
          if !mark.quote.comment.isEmpty {
            Text(mark.quote.comment).appFont(.message).textSelection(.enabled)
              .accessibilityIdentifier("quote-detail-comment")
          }
          Button("Ir ao trecho citado", systemImage: "text.quote", action: source)
            .accessibilityIdentifier("quote-go-source")
          if mark.pending {
            Button("Editar comentário", systemImage: "pencil", action: edit)
              .accessibilityIdentifier("quote-edit")
            Button("Remover citação", systemImage: "trash", role: .destructive, action: remove)
              .foregroundStyle(theme.color(.error)).accessibilityIdentifier("quote-remove")
          } else {
            Button("Ir à mensagem com o comentário", systemImage: "bubble.left", action: message)
              .accessibilityIdentifier("quote-go-message")
            // Hides only this device's response mark; the sent comment and its bubble remain.
            Button("Remover marcação", systemImage: "trash", role: .destructive, action: remove)
              .foregroundStyle(theme.color(.error)).accessibilityIdentifier("quote-dismiss")
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
      }.background(theme.color(.background)).foregroundStyle(theme.color(.text))
        .navigationTitle("Citação · \(mark.number)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar", action: close) } }
    }
    #if os(iOS)
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    #else
    .frame(width: 440, height: 380)
    #endif
    .tint(theme.color(.textAccent))
  }
}

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
                  Label(attachment.name, systemImage: attachment.mime.hasPrefix("image/") ? "photo" : "doc")
                    .font(.caption).foregroundStyle(theme.color(.textSecondary)).padding(.leading, 12)
                }
              }
            }
          }
        }.frame(maxHeight: 210).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(14).foregroundStyle(theme.color(.text))
      .background(theme.color(.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
      .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.color(.border), lineWidth: 0.7) }
      .disabled(draft.sending || draft.importing)
  }
}
