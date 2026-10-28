import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct ConversationStreamLogTests {
  private func event(_ type: String, _ body: String = "", ordinal: Int = 0) -> ConversationEvent {
    let fields = ["\"assistantMessageID\":\"a\"", "\"ordinal\":\(ordinal)", body].filter { !$0.isEmpty }
    return try! JSONDecoder().decode(ConversationEvent.self, from: Data(
      "{\"type\":\"\(type)\",\"created\":3,\"data\":{\(fields.joined(separator: ","))}}".utf8))
  }
  private func running(_ texts: [String]) -> ConversationMessage {
    var message = ConversationMessage(id: "a", type: "assistant", time: MessageTime(created: 1))
    message.content = texts.map { ConversationPart(type: "text", text: $0) }
    return message
  }

  @Test func aReadMidStreamKeepsEveryDeltaOnceWhetherOrNotItHadThem() {
    var log = ConversationStreamLog()
    log.record(event("session.text.started"))
    for word in ["Um", " dois", " três", " quatro"] { log.record(event("session.text.delta", "\"delta\":\"\(word)\"")) }
    // The server's read lacks the streamed text, or has part of it, or all of it: the result is the same.
    for read in ["", "Um dois", "Um dois três quatro"] {
      #expect(log.reconcile(running([read])).content?.first?.text == "Um dois três quatro")
    }
    // A read that moved ahead, or changed the text, is taken as it is.
    #expect(log.reconcile(running(["Um dois três quatro cinco"])).content?.first?.text == "Um dois três quatro cinco")
    #expect(log.reconcile(running(["Outro texto"])).content?.first?.text == "Outro texto")
    // A part the read does not have yet follows in order.
    log.record(event("session.text.started", ordinal: 1))
    log.record(event("session.text.delta", "\"delta\":\"Segunda\"", ordinal: 1))
    #expect(log.reconcile(running(["Um"])).content?.map(\.text) == ["Um dois três quatro", "Segunda"])
  }

  @Test func lostDeltasPauseThePartUntilItsEndInsteadOfLeavingAGap() {
    var log = ConversationStreamLog()
    log.record(event("session.text.started"))
    log.record(event("session.text.delta", "\"delta\":\"Antes\""))
    // The stream reconnected: what was sent meanwhile is gone.
    log.interrupt([running(["Antes"])])
    let after = event("session.text.delta", "\"delta\":\" depois\"")
    log.record(after)
    #expect(!log.accepts(after), "a delta after the gap would continue a text with a hole in it")
    #expect(log.reconcile(running([""])).content?.first?.text == "Antes")
    log.record(event("session.text.ended", "\"text\":\"Antes, durante e depois\""))
    #expect(log.accepts(after))
    #expect(log.reconcile(running([""])).content?.first?.text == "Antes, durante e depois")
  }

  @Test func aPartRunningBeforeTheLogSawItStartShowsWhatArrivesAfterAMarker() {
    var log = ConversationStreamLog()
    // Opened mid-answer: the read has no streamed text and the beginning never arrives as deltas.
    _ = log.reconcile(running([""]))
    let delta = event("session.text.delta", "\"delta\":\"meio da frase\"")
    log.record(delta)
    #expect(!log.accepts(delta), "it reaches the transcript through reconcile, after the marker")
    #expect(log.headlessMessages == ["a"])
    #expect(log.reconcile(running([""])).content?.first?.text == "…meio da frase")
    // Later deltas keep it live, whether the shown text or a fresh read is reconciled.
    log.record(event("session.text.delta", "\"delta\":\" e o fim\""))
    #expect(log.reconcile(running(["…meio da frase"])).content?.first?.text == "…meio da frase e o fim")
    #expect(log.reconcile(running([""])).content?.first?.text == "…meio da frase e o fim")
    // Once a whole line arrived, the fragment before it gives way: the rest keeps its own blocks.
    log.record(event("session.text.delta", "\"delta\":\".\\n68. Outra linha\\n69. Mais uma\""))
    #expect(log.reconcile(running([""])).content?.first?.text == "…\n\n68. Outra linha\n69. Mais uma")
    // The end event brings the whole text, beginning included.
    log.record(event("session.text.ended", "\"text\":\"Começo, meio da frase e o fim\""))
    #expect(log.headlessMessages.isEmpty)
    #expect(log.reconcile(running(["…\n\n68. Outra linha\n69. Mais uma"])).content?.first?.text == "Começo, meio da frase e o fim")
    var finished = running(["Começo, meio da frase e o fim"])
    finished.time.completed = 4
    #expect(log.reconcile(finished).content?.first?.text == "Começo, meio da frase e o fim")
  }

  @Test func aConversationOffScreenRecordsTheSameFramesOnceFromEitherFeed() {
    var log = ConversationStreamLog()
    let frames = [event("session.text.started")] + ["Um", " dois", " três", " quatro"].map {
      event("session.text.delta", "\"delta\":\"\($0)\"")
    }
    // The screen's feed records the first frames, then closes; the session list's feed saw them all and records
    // the rest, interleaved with the frames the screen already had.
    for (sequence, frame) in frames.enumerated().prefix(3) { log.record(frame, sequence: sequence + 1) }
    for (sequence, frame) in frames.enumerated() { log.record(frame, sequence: sequence + 1) }
    #expect(log.reconcile(running([""])).content?.first?.text == "Um dois três quatro")
    // Back on screen, the screen's feed continues where the list's was.
    log.record(event("session.text.delta", "\"delta\":\" cinco\""), sequence: 6)
    log.record(event("session.text.delta", "\"delta\":\" cinco\""), sequence: 6)
    #expect(log.reconcile(running(["Um dois"])).content?.first?.text == "Um dois três quatro cinco")
  }

  @Test func aDisconnectionPausesPartsTheScreenNeverShowed() {
    var log = ConversationStreamLog()
    // Recorded off screen: the shown messages do not have this part yet.
    log.record(event("session.text.started", ordinal: 0), sequence: 1)
    log.record(event("session.text.delta", "\"delta\":\"Fora da tela\"", ordinal: 0), sequence: 2)
    log.interrupt([])
    log.record(event("session.text.delta", "\"delta\":\" depois do buraco\"", ordinal: 0), sequence: 3)
    #expect(log.reconcile(running([""])).content?.first?.text == "Fora da tela")
  }
}
