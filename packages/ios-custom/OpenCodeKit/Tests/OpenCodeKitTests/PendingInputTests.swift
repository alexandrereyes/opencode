import Foundation
import Testing

@testable import OpenCodeKit

private func pendingItem(_ id: String, delivery: String = "steer", type: String = "user", created: Double)
  throws -> InboxItem
{
  try JSONDecoder().decode(InboxItem.self, from: Data("""
    {"id":"\(id)","sessionID":"ses_pending","type":"\(type)","delivery":"\(delivery)",
     "payload":{"text":"\(id)","metadata":{"displayText":"\(id)"},"files":[]},"time":{"created":\(created)}}
    """.utf8))
}

private func transcript(_ entries: [(String, String, Double)]) -> [ConversationMessage] {
  entries.map { ConversationMessage(id: $0.0, type: $0.1, time: MessageTime(created: $0.2)) }
}

// The cases mirror the web client's `solid-pending-status.test.ts`.
@Test func pendingSteerStatusFollowsTheWebRules() throws {
  let first = try pendingItem("msg_first", created: 1)
  #expect(PendingInputs.status(first, inbox: [first], messages: [], running: false) == .starting)
  #expect(PendingInputs.status(first, inbox: [first], messages: [], running: true) == .starting)

  let delivered = transcript([("msg_first", "user", 1), ("msg_reply", "assistant", 2)])
  let steer = try pendingItem("msg_steer", created: 3)
  #expect(PendingInputs.status(steer, inbox: [steer], messages: delivered, running: true) == .steering)
  let queued = try pendingItem("msg_steer", delivery: "queue", created: 3)
  #expect(PendingInputs.status(queued, inbox: [queued], messages: delivered, running: true) == .queued)

  // Rapid follow-ups join the starting execution until it delivers input.
  let second = try pendingItem("msg_second", created: 2)
  #expect(PendingInputs.status(second, inbox: [first, second], messages: [], running: true) == .starting)

  // An execution that ended without delivering it strands the steer; a later admission starts fresh.
  let ended = transcript([("msg_old", "user", 0), ("idle_1", "idle", 5)])
  let stranded = try pendingItem("msg_stranded", created: 4)
  let retry = try pendingItem("msg_retry", created: 6)
  #expect(PendingInputs.status(stranded, inbox: [stranded, retry], messages: ended, running: false) == .stranded)
  #expect(PendingInputs.status(retry, inbox: [stranded, retry], messages: ended, running: false) == .starting)
  #expect(PendingInputs.status(stranded, inbox: [stranded, retry], messages: ended, running: true) == .starting)

  // A later execution starts fresh after an earlier turn delivered input.
  let next = try pendingItem("msg_next", created: 6)
  #expect(PendingInputs.status(next, inbox: [next], messages: ended, running: true) == .starting)

  let synthetic = try pendingItem("msg_synthetic", type: "synthetic", created: 3)
  #expect(PendingInputs.status(synthetic, inbox: [synthetic], messages: [], running: true) == nil)
}

@Test func pendingPresentationMatchesTheWebBubble() {
  #expect(PendingInputStatus.starting.actions && !PendingInputStatus.starting.waiting)
  #expect(PendingInputStatus.steering.actions && PendingInputStatus.steering.waiting)
  #expect(PendingInputStatus.stranded.actions && PendingInputStatus.stranded.waiting)
  #expect(!PendingInputStatus.queued.actions && !PendingInputStatus.queued.waiting)
}

@Test func optimisticItemRendersTheRequestUnderItsAdmissionID() {
  let model = ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low")
  let request = PromptRequest(
    document: ComposerDocument(text: "Olá"), delivery: .queue, agent: "build", model: model)
  let item = InboxItem(optimistic: request, sessionID: "ses_a", attachments: ["foto.png"], created: 7)
  #expect(item.id == request.id && item.sessionID == "ses_a" && item.queuedUser && item.time?.created == 7)
  #expect(item.message.displayText == "Olá")
  #expect(item.payload.metadata?["attachments"] == .array([.object(["name": .string("foto.png")])]))
  #expect(InboxItem(optimistic: request, sessionID: "ses_a", attachments: [], created: 7)
    .payload.metadata?["attachments"] == nil)
  #expect(PromptRequest.newID() != PromptRequest.newID())
}

@Test func pendingSteersExcludeQueuedSyntheticAndDeliveredItems() throws {
  let steer = try pendingItem("msg_steer", created: 3)
  let inbox = [
    try pendingItem("msg_queued", delivery: "queue", created: 1), steer,
    try pendingItem("msg_synthetic", type: "synthetic", created: 2),
    try pendingItem("msg_delivered", created: 4),
  ]
  let messages = transcript([("msg_delivered", "user", 5)])
  #expect(PendingInputs.steers(inbox, messages: messages).map(\.id) == ["msg_steer"])
  let message = steer.message
  #expect(message.id == "msg_steer" && message.type == "user" && message.displayText == "msg_steer")
  #expect(message.time.created == 3 && message.files == [])
}
