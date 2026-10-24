import Foundation
import Testing

@testable import OpenCodeKit

private func marked(_ id: String, _ type: String = "assistant", day: Double = 0, text: [String] = []) -> ConversationMessage {
  var message = ConversationMessage(id: id, type: type, time: MessageTime(created: (day * 86_400 + 43_200) * 1000))
  message.content = text.map { ConversationPart(type: "text", text: $0) }
  return message
}

@Test func transcriptMarksStartEachCalendarDay() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let marks = TranscriptMarks([
    marked("a", "user"), marked("b"), marked("c", "user", day: 1), marked("d", day: 1), marked("e", day: 3),
  ], working: false, calendar: calendar)
  #expect(marks.days == ["a", "c", "e"])
}

@Test func transcriptMarksFooterTheLastResponseOfEndedTurns() {
  let messages = [
    marked("u1", "user"), marked("a1", text: ["primeira"]), marked("tool"), marked("a2", text: ["final"]),
    marked("u2", "user"), marked("a3", text: ["em andamento"]), marked("tail"),
  ]
  // Later response text in the same turn moves the footer; an idle Session ends the last turn.
  #expect(TranscriptMarks(messages, working: false).footers == ["a2", "a3", "tail"])
  // While the Session works, only turns that a later prompt already ended keep their footer.
  #expect(TranscriptMarks(messages, working: true).footers == ["a2"])
}

@Test func transcriptMarksTreatJoinedEmptyTextsAsResponseText() {
  // `responseText` joins two empty parts into a separator, which the footer has always treated as text.
  let marks = TranscriptMarks([marked("u", "user"), marked("a", text: ["final"]), marked("b", text: ["", ""])], working: false)
  #expect(!marks.footers.contains("a") && marks.footers.contains("b"))
}

@Test func chatQuoteIndexEqualityFollowsItsMarks() throws {
  func user(_ id: String, quote: String) throws -> ConversationMessage {
    let metadata = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([
      ChatQuote(id: quote, messageID: "m", partID: "m:text:0", text: "Trecho"),
    ]))
    return try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(JSONValue.object([
      "id": .string(id), "type": .string("user"), "time": .object(["created": .number(1)]),
      "metadata": .object(["quotes": metadata]),
    ])))
  }
  var first = ChatQuoteIndex()
  first.update([try user("u", quote: "q1")])
  var same = ChatQuoteIndex()
  same.update([try user("u", quote: "q1")])
  var other = ChatQuoteIndex()
  other.update([try user("u", quote: "q2")])
  #expect(first == same)
  #expect(first != other)
  #expect(first != ChatQuoteIndex())
}
