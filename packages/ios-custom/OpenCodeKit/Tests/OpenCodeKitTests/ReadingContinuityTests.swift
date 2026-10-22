import Foundation
import Testing

@testable import OpenCodeKit

private func answer(_ id: String, _ parts: [ConversationPart], finish: String? = "stop")
  -> ConversationMessage
{
  var message = ConversationMessage(
    id: id, type: "assistant", time: MessageTime(created: 1, completed: 2))
  message.content = parts
  message.finish = finish
  return message
}
private func text(_ phase: String? = nil) -> ConversationPart {
  ConversationPart(
    type: "text", text: "Resposta", state: phase.map { .object(["phase": .string($0)]) })
}
private let tool = ConversationPart(type: "tool", id: "tool", name: "read")

@Test func finalDividerSimpleReplyAndActivity() {
  #expect(ConversationProjection.finalAnswerDividers([answer("a", [text()])]).isEmpty)
  #expect(
    ConversationProjection.finalAnswerDividers([answer("a", [tool, text()])]) == ["a:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [.init(type: "reasoning", text: "Pensou"), text()])
    ]) == ["a:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [text("commentary"), tool], finish: "tool-calls"),
      answer("b", [text("final_answer")]),
    ]) == ["b:text:0"])
}

@Test func finalDividerEligibility() {
  for invalid in ["streaming", "error", "retry", "tool-calls"] {
    var message = answer("a", [tool, text()])
    if invalid == "streaming" { message.time.completed = nil }
    if invalid == "error" { message.error = .object(["message": .string("Erro")]) }
    if invalid == "retry" { message.retry = .object(["attempt": .number(1)]) }
    if invalid == "tool-calls" { message.finish = "tool-calls" }
    #expect(ConversationProjection.finalAnswerDividers([message]).isEmpty)
  }
}

@Test func finalDividerSequencesAcrossMessagesAndPhases() {
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [tool, text(), text()]), answer("b", [text(), text()]),
    ]) == ["b:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [tool, text("final_answer"), text("final_answer")]), answer("b", [text()]),
    ]) == ["a:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [tool, text("other"), text()])
    ]) == ["a:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [tool, text("final_answer"), text("commentary")]), answer("b", [text()]),
    ]) == ["a:text:0", "b:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [tool, text("final_answer"), text("commentary")])
    ]) == ["a:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [tool, text(), tool, text()])
    ]) == ["a:text:0", "a:text:1"])
}

@Test func finalDividerHistoryNoticesAndHiddenActivity() {
  let user = ConversationMessage(id: "u", type: "user", time: MessageTime(created: 0))
  let notice = ConversationMessage(id: "n", type: "synthetic", time: MessageTime(created: 0))
  #expect(
    ConversationProjection.finalAnswerDividers([
      notice, answer("a", [text()]), user, answer("b", [text()]),
      answer("c", [tool, text()]),
    ]) == ["a:text:0", "c:text:0"])
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("a", [.init(type: "tool", id: "todo", name: "todowrite"), text()])
    ]).isEmpty)
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer(
        "a",
        [
          .init(
            type: "tool", id: "todo", name: "todowrite",
            state: .object(["status": .string("error")])), text(),
        ])
    ]).isEmpty)
  var idle = ConversationMessage(id: "idle", type: "idle", time: MessageTime(created: 2))
  idle.outcome = "succeeded"
  #expect(
    ConversationProjection.finalAnswerDividers([
      answer("first", [text("final_answer")]), idle, answer("second", [text()]),
    ]).isEmpty)
  let nextUser = ConversationMessage(id: "next-user", type: "user", time: MessageTime(created: 3))
  #expect(
    ConversationProjection.finalAnswerDividers([
      user, answer("old", [tool, text()]), nextUser, answer("new", [tool, text()]),
    ]) == ["old:text:0", "new:text:0"])
}

@Test func readingCaptureIncludesPartialResponsesAndBubbles() {
  let frames = [
    ReadingMessageFrame(id: "response", top: -120, bottom: 400),
    ReadingMessageFrame(id: "bubble", top: 420, bottom: 600),
  ]
  #expect(
    ReadingCapture.target(followTail: false, frames: frames, usableTop: 80, viewportBottom: 700)
      == .message(id: "response", offset: 200))
  #expect(
    ReadingCapture.target(followTail: false, frames: frames, usableTop: 410, viewportBottom: 700)
      == .message(id: "bubble", offset: -10))
  #expect(
    ReadingCapture.target(followTail: true, frames: frames, usableTop: 80, viewportBottom: 700)
      == .followTail)
  #expect(
    ReadingCapture.target(followTail: false, frames: [], usableTop: 0, viewportBottom: 700) == nil)
  #expect(ReadingCapture.clampedOffset(800, height: 300) == 299)
  #expect(ReadingCapture.clampedOffset(-500, height: 300) == -500)
  #expect(ReadingCapture.clampedOffset(-48, height: 90) == -48)
}

@Test func readingRestoreBudgetMissingAndFollow() {
  let position = ReadingPosition(.message(id: "old", offset: 72))
  #expect(ReadingRestoreDecision.decide(nil, loaded: [], hasOlder: true, pages: 0) == .tail)
  #expect(
    ReadingRestoreDecision.decide(.init(.followTail), loaded: [], hasOlder: true, pages: 0) == .tail
  )
  #expect(
    ReadingRestoreDecision.decide(position, loaded: ["old"], hasOlder: true, pages: 5)
      == .anchor("old", 72))
  #expect(
    ReadingRestoreDecision.decide(
      position, loaded: ["old", "new-while-away"], hasOlder: true, pages: 0)
      == .anchor("old", 72))
  #expect(
    ReadingRestoreDecision.decide(position, loaded: [], hasOlder: true, pages: 4) == .loadOlder)
  #expect(
    ReadingRestoreDecision.decide(position, loaded: [], hasOlder: true, pages: 5) == .offerResume)
  #expect(ReadingRestoreDecision.decide(position, loaded: [], hasOlder: false, pages: 5) == .tail)
}

@Test @MainActor func readingPersistenceRoundTripServerIsolationAndLRU() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ReadingPositionStore(server: "http://localhost:4177", root: root, capacity: 2)
  #expect(
    store.file.deletingPathExtension().lastPathComponent
      == DraftPersistence(
        server: "http://localhost:4177", sessionID: "A", root: root
      ).directory
      .deletingLastPathComponent().lastPathComponent)
  let position = ReadingPosition(
    .message(id: "message", offset: 123.5), updatedAt: Date(timeIntervalSince1970: 100),
    viewportTop: 92)
  store.set(position, sessionID: "A")
  store.set(.init(.followTail), sessionID: "B")
  #expect(store.position("A") == position)
  store.set(.init(.followTail), sessionID: "C")
  #expect(store.position("B") == nil)
  try store.flush()
  let restored = ReadingPositionStore(server: "http://localhost:4177", root: root, capacity: 2)
  #expect(restored.position("A") == position)
  let legacy = try JSONDecoder().decode(
    ReadingPosition.self,
    from: Data(
      #"{"target":{"message":{"id":"message","offset":123.5}},"updatedAt":0}"#.utf8))
  #expect(legacy.target == position.target)
  #expect(legacy.viewportTop == nil)
  #expect(restored.position("C")?.target == .followTail)
  #expect(ReadingPositionStore(server: "http://other", root: root).position("A") == nil)
  let json = try String(contentsOf: store.file, encoding: .utf8)
  #expect(!json.contains("localhost"))
  #expect(!json.contains("password"))
}

@Test @MainActor func expansionMemoryKeepsExplicitCollapseAndOnlySixteenSessions() {
  let memory = ConversationExpansionMemory(capacity: 2)
  memory.set(["step": false, "tool": true], sessionID: "parent")
  memory.set(["child": true], sessionID: "child")
  #expect(memory.values("parent") == ["step": false, "tool": true])
  memory.set([:], sessionID: "other")
  #expect(memory.values("child").isEmpty)
  #expect(memory.values("parent")["step"] == false)
}

@Test func returnOnlyManualShiftCanSend() {
  for shifted in [false, true] {
    for automatic in [false, true] {
      for locked in [false, true] {
        for available in [false, true] {
          for marked in [false, true] {
            for suggestions in [false, true] {
              for ready in [false, true] {
                #expect(
                  ComposerReturn.shouldSubmit(
                    shifted: shifted, autoShifted: automatic,
                    shiftLocked: locked, available: available, markedText: marked,
                    suggestionsOpen: suggestions, canSubmit: ready)
                    == (shifted && !automatic && !locked && available && !marked && !suggestions
                      && ready))
              }
            }
          }
        }
      }
    }
  }
}
