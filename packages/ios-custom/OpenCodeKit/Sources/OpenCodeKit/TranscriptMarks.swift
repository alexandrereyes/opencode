import Foundation

/// Per-message transcript decorations derived in one pass, so rows never search the history.
public struct TranscriptMarks: Sendable, Equatable {
  /// Messages that start a calendar day, including the first loaded message.
  public private(set) var days: Set<String> = []
  /// Messages whose turn has no later response text and has ended (a later prompt or an idle Session).
  /// Rows still require their own completed, error-free response before showing the usage footer.
  public private(set) var footers: Set<String> = []

  public init(_ messages: [ConversationMessage], working: Bool, calendar: Calendar = .current) {
    var previous: Date?
    for message in messages {
      let date = Date(timeIntervalSince1970: message.time.created / 1000)
      if previous.map({ !calendar.isDate(date, inSameDayAs: $0) }) ?? true { days.insert(message.id) }
      previous = date
    }
    var textAfter = false
    var promptAfter = false
    for message in messages.reversed() {
      if message.type == "user" {
        promptAfter = true
        textAfter = false
        continue
      }
      if !textAfter && (promptAfter || !working) { footers.insert(message.id) }
      let texts = (message.content ?? []).filter { $0.type == "text" }.compactMap(\.text)
      if texts.count > 1 || texts.first?.isEmpty == false { textAfter = true }
    }
  }
}
