import OpenCodeKit
import SwiftUI

struct ConversationQuoteContext {
  var index = ChatQuoteIndex()
  var pending: [ChatQuote] = []
  var dismissed: Set<String> = []
  var revealing: String?
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
      && lhs.revealing == rhs.revealing && lhs.target == rhs.target && lhs.active == rhs.active
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
        .navigationTitle("Citação · \(mark.number)").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar", action: close) } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).tint(theme.color(.textAccent))
  }
}
