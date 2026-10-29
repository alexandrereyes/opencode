import Foundation

/// Per-message transcript decorations derived in one pass, so rows never search the history.
public struct TranscriptMarks: Sendable, Equatable {
  /// Messages that start a calendar day, including the first loaded message.
  public private(set) var days: Set<String> = []
  /// Messages whose turn has no later response text and has ended (a later prompt or an idle Session).
  /// Rows still require their own completed, error-free response before showing the usage footer.
  public private(set) var footers: Set<String> = []

  public init(_ messages: [ConversationMessage], working: Bool, calendar: Calendar = .current) {
    // The previous message's day, found once per day instead of asking the calendar about every message.
    var day: (start: Date, end: Date)?
    var previous: Date?
    for message in messages {
      let date = Date(timeIntervalSince1970: message.time.created / 1000)
      defer { previous = date }
      if let day, date >= day.start, date < day.end { continue }
      if day == nil, let previous, calendar.isDate(date, inSameDayAs: previous) { continue }
      days.insert(message.id)
      day = calendar.dateInterval(of: .day, for: date).map { ($0.start, $0.end) }
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
      // More than one text, or a first one with content.
      var texts = 0
      for part in message.content ?? [] where part.type == "text" {
        guard let text = part.text else { continue }
        texts += 1
        if texts > 1 || !text.isEmpty {
          textAfter = true
          break
        }
      }
    }
  }
}
