import Foundation
import Testing
@testable import OpenCodeKit

private actor RevertClient: SessionRevertActions {
  var calls: [String] = []
  var fail: String?
  let boundaries = [RevertBoundary(sessionID: "child", messageID: "b"), RevertBoundary(sessionID: "grandchild", messageID: "c")]
  init(fail: String? = nil) { self.fail = fail }
  func record(_ call: String) throws {
    calls.append(call)
    if call == fail { throw ClientError.http(503) }
  }
  func revertBoundaries(_ sessionID: String, cutoff: Double?, directory: String) async throws -> [RevertBoundary] {
    try record(cutoff == nil ? "plan-clear" : "plan-\(Int(cutoff!))")
    return boundaries
  }
  func interrupt(_ sessionID: String, resume: Bool) async throws { try record("interrupt-" + sessionID) }
  func waitForIdle(_ sessionID: String) async throws { try record("wait-" + sessionID) }
  func stageRevert(_ boundary: RevertBoundary, files: Bool?) async throws {
    try record("stage-\(boundary.sessionID)-\(files == false ? "no-files" : "files")")
  }
  func clearRevert(_ sessionID: String) async throws { try record("clear-" + sessionID) }
  func inbox(_ sessionID: String) async throws -> [InboxItem] {
    try record("inbox-" + sessionID)
    return [revertInbox("queued"), revertInbox("future", created: Double.greatestFiniteMagnitude), revertInbox("control", type: "compact")]
  }
  func cancelInbox(_ id: String, sessionID: String) async throws { try record("cancel-" + id) }
}

private func revertUser(_ id: String, created: Double = 100) -> ConversationMessage {
  var message = ConversationMessage(id: id, type: "user", time: .init(created: created))
  message.text = "Mensagem " + id
  return message
}
private func revertInbox(_ id: String, type: String = "user", created: Double = 1) -> InboxItem {
  .init(id: id, sessionID: "root", type: type, delivery: .queue,
    payload: .init(text: id, metadata: nil, files: nil, agents: nil, skills: nil), time: .init(created: created))
}

@Test func revertSelectsAnyUserAndRedoAdvancesOneBoundary() {
  let messages = [revertUser("a"), ConversationMessage(id: "b", type: "assistant", time: .init(created: 101)), revertUser("c")]
  #expect(SessionRevert.undo(messages, boundary: nil)?.id == "c")
  #expect(SessionRevert.undo(messages, boundary: "c")?.id == "a")
  #expect(SessionRevert.undo(messages, boundary: "a") == nil)
  #expect(SessionRevert.redo(messages, boundary: "a")?.id == "c")
  #expect(SessionRevert.redo(messages, boundary: "c") == nil)
}

@Test func revertPreservesFamilyOrderAndOnlyRootRestoresFiles() async {
  let client = RevertClient()
  let result = await SessionRevert.perform(sessionID: "root", target: revertUser("a"), directory: "/fake",
    active: ["child"], pending: [revertInbox("queued")], using: client)
  #expect(result.succeeded)
  #expect(result.failures.isEmpty)
  #expect(await client.calls == ["plan-100", "interrupt-child", "wait-child", "stage-child-no-files",
    "stage-grandchild-no-files", "interrupt-root", "wait-root", "stage-root-files", "inbox-root", "cancel-queued"])
}

@Test func redoClearsDescendantsBeforeRootWithoutInboxCancellation() async {
  let client = RevertClient()
  let result = await SessionRevert.perform(sessionID: "root", target: nil, directory: "/fake",
    active: ["grandchild"], pending: [revertInbox("queued")], using: client)
  #expect(result.succeeded)
  #expect(await client.calls == ["plan-clear", "clear-child", "interrupt-grandchild", "wait-grandchild", "clear-grandchild", "clear-root"])
}

@Test func revertReportsPartialChildFailureButStillStagesRootLikeWeb() async {
  let client = RevertClient(fail: "stage-child-no-files")
  let result = await SessionRevert.perform(sessionID: "root", target: revertUser("a"), directory: "/fake",
    active: [], pending: [], using: client)
  #expect(result.succeeded)
  #expect(result.failures.count == 1)
  #expect(await client.calls.contains("stage-root-files"))
}

@Test func revertWaitFailureDoesNotStageRootOrCancelInbox() async {
  let client = RevertClient(fail: "wait-root")
  let result = await SessionRevert.perform(sessionID: "root", target: revertUser("a"), directory: "/fake",
    active: [], pending: [], using: client)
  #expect(!result.succeeded)
  #expect(result.failures.count == 1)
  #expect(await !client.calls.contains("stage-root-files"))
  #expect(await !client.calls.contains("inbox-root"))
}

@Test func familyPlanningFailureRemainsVisibleWhileRootProceeds() async {
  let client = RevertClient(fail: "plan-100")
  let result = await SessionRevert.perform(sessionID: "root", target: revertUser("a"), directory: "/fake",
    active: [], pending: [], using: client)
  #expect(result.succeeded)
  #expect(result.failures.count == 1)
  #expect(await client.calls == ["plan-100", "interrupt-root", "wait-root", "stage-root-files", "inbox-root", "cancel-queued"])
}

@Test func restorationRequiresTheWebPresentationMetadataShape() {
  var message = revertUser("a")
  message.text = "Texto real"
  message.metadata = ["displayText": .string("Metadados incompletos")]
  #expect(RevertedPrompt(message).document.text == "Texto real")
  message.metadata?["comments"] = .array([])
  #expect(RevertedPrompt(message).document.text == "Metadados incompletos")
}

@Test func removingRestoredCommentAlsoRemovesItsGeneratedFileContext() {
  var message = revertUser("a")
  message.metadata = ["displayText": .string("Revisar"), "comments": .array([
    .object(["path": .string("a.swift"), "comment": .string("Veja @b.swift.")])])]
  message.files = ["a.swift", "b.swift"].map {
    .object(["source": .object(["type": .string("uri"), "uri": .string("file:///repo/" + $0)])])
  }
  var context = RevertedPrompt(message, directory: "/repo").context
  #expect(context.files.isEmpty)
  #expect(context.allFiles.count == 2)
  context.comments = .array([])
  #expect(context.allFiles.isEmpty)
  #expect(context.text.isEmpty)
}

private actor RevertSubmissionActions: ConversationActions {
  var calls: [String] = []
  func session(_ id: String) async throws -> Session {
    try JSONDecoder().decode(Session.self, from: Data(#"{"id":"root","projectID":"global","agent":"old","location":{"directory":"/fake"},"time":{"created":1,"updated":1}}"#.utf8))
  }
  func selectAgent(_ agent: String, sessionID: String) async throws { calls.append("agent") }
  func selectModel(_ model: ModelReference, sessionID: String) async throws { calls.append("model") }
  func prompt(_ request: PromptRequest, sessionID: String) async throws { calls.append("prompt") }
  func cancelInbox(_ id: String, sessionID: String) async throws { calls.append("cancel") }
  func commitRevert(_ sessionID: String) async throws { calls.append("commit") }
}

@Test func newAdmissionCommitsRevertBetweenAgentAndModelSelection() async throws {
  for delivery in [PromptDelivery.steer, .queue] {
    let client = RevertSubmissionActions()
    let model = ModelReference(id: "model", providerID: "provider")
    let request = PromptRequest(text: "Novo pedido", delivery: delivery, agent: "build", model: model)
    let submission = PromptSubmission(request: request, sessionID: "root", agent: "build", model: model, commitsRevert: true)
    try await submission.send(using: client)
    #expect(await client.calls == (delivery == .steer ? ["agent", "commit", "model", "prompt"] : ["commit", "prompt"]))
  }
}

@Test func revertedPromptRestoresTokensQuotesImagesPathsAndContextWithoutChangingSelections() throws {
  var message = revertUser("a")
  message.text = "Expanded server text"
  message.metadata = ["displayText": .string("Leia @file"), "comments": .array([.object(["path": .string("a.swift"), "comment": .string("Rever")])]),
    "attachments": .array([.object(["name": .string("log.txt"), "mime": .string("text/plain"), "path": .string("/tmp/log.txt")])])]
  message.files = [
    .object(["source": .object(["type": .string("uri"), "uri": .string("file:///repo/a.swift")]),
      "mention": .object(["start": .number(5), "end": .number(10), "text": .string("@file")])]),
    .object(["source": .object(["type": .string("uri"), "uri": .string("file:///repo/context.swift")])]),
    .object(["source": .object(["type": .string("inline")]), "data": .string("aGk="), "mime": .string("image/png"), "name": .string("image.png")]),
  ]
  let prompt = RevertedPrompt(message)
  #expect(prompt.document.text == "Leia @file")
  #expect(prompt.document.validTokens.first?.token.value == "/repo/a.swift")
  #expect(prompt.attachments.count == 2)
  #expect(prompt.attachments.first?.remotePath == "/tmp/log.txt")
  #expect(prompt.bytes.values.first == Data("hi".utf8))
  #expect(prompt.context.files.count == 1)
  let snapshot = DraftSnapshot(document: prompt.document, attachments: prompt.attachments, revertedContext: prompt.context)
  #expect(try JSONDecoder().decode(DraftSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
  let request = PromptRequest(document: prompt.document, delivery: .steer, agent: "build", model: .init(id: "m", providerID: "p"),
    metadata: prompt.context.metadata, contextFiles: prompt.context.files)
  #expect(request.files?.count == 2)
  #expect(request.metadata["comments"] == message.metadata?["comments"])
}

@Test func revertClientUsesInstalledProtocolAndLocation() async throws {
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { request in
    let url = try #require(request.url)
    if url.path.contains("custom.session-family") {
      #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/fake repo")
      return (Data(#"{"output":[]}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    if url.path.hasSuffix("/stage") {
      let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
      #expect(body.object?["messageID"] == .string("a"))
      #expect(body.object?["files"] == .bool(false))
    }
    return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
  }
  _ = try await client.revertBoundaries("root", cutoff: 100, directory: "/fake repo")
  try await client.stageRevert(.init(sessionID: "root", messageID: "a"), files: false)
  try await client.clearRevert("root")
  try await client.waitForIdle("root")
  try await client.commitRevert("root")
}
