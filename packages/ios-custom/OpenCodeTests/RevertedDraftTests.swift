import Foundation
import XCTest
@testable import OpenCode
@testable import OpenCodeKit

@MainActor final class RevertedDraftTests: XCTestCase {
  func testRestorationReplacesDraftAndPersistsTokensWithoutChangingModelOrAgent() async throws {
    let draft = ConversationDraft(server: "http://127.0.0.1:4177/undo-test-" + UUID().uuidString, id: "ses_owned")
    await draft.load()
    draft.text = NSAttributedString(string: "rascunho antigo")
    draft.model = .init(id: "selected", providerID: "provider")
    draft.agent = "selected-agent"
    draft.replacing = "old-queue"
    let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(#"{"id":"msg_owned","type":"user","time":{"created":1},"text":"Expandido","metadata":{"displayText":"Leia @arquivo","comments":[]},"files":[{"source":{"type":"uri","uri":"file:///repo/a.swift"},"mention":{"text":"@arquivo","start":5,"end":13}}]}"#.utf8))
    try draft.projectReverted(RevertedPrompt(message))
    try await draft.persistReverted(RevertedPrompt(message))
    XCTAssertEqual(draft.document.text, "Leia @arquivo")
    XCTAssertEqual(draft.document.validTokens.count, 1)
    XCTAssertEqual(draft.model?.id, "selected")
    XCTAssertEqual(draft.agent, "selected-agent")
    XCTAssertNil(draft.replacing)
    XCTAssertNil(draft.submission)
    let saved = try await draft.persistence.load().0
    XCTAssertEqual(saved?.document, draft.document)
    await draft.clear()
    XCTAssertNil(draft.revertedContext)
    try await draft.discard()
  }

  func testRestorationReplacesOldAttachments() async throws {
    let draft = ConversationDraft(server: "http://127.0.0.1:4177/undo-test-" + UUID().uuidString, id: "ses_owned")
    await draft.load()
    draft.attachments = [.init(name: "velho", mime: "text/plain", size: 0, remotePath: "/old")]
    var message = ConversationMessage(id: "msg_owned", type: "user", time: .init(created: 1))
    message.text = "Novo"
    message.metadata = ["displayText": .string("Novo"), "comments": .array([]), "attachments": .array([
      .object(["name": .string("novo.txt"), "mime": .string("text/plain"), "path": .string("/new")])])]
    try draft.projectReverted(RevertedPrompt(message))
    XCTAssertEqual(draft.attachments.map(\.name), ["novo.txt"])
    try await draft.discard()
  }

  func testQueuedRevertsJoinDuplicatesAndPreserveEditsWhileWaiting() async throws {
    let server = RevertTestServer()
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
      try await server.respond($0)
    }
    let store = ConversationStore(id: "root", client: client, hub: EventHub(client: client))
    await store.refresh()
    let draft = ConversationDraft(server: "revert-test-" + UUID().uuidString, id: "root")
    await draft.load()
    let last = try XCTUnwrap(store.messages.last)
    let first = Task { await store.reversion.perform(target: last, store: store, draft: draft) }
    await server.waitForStage()
    draft.text = NSAttributedString(string: "Edição após restaurar")
    let joined = expectation(description: "Duplicate entered")
    let duplicate = Task {
      joined.fulfill()
      await store.reversion.perform(target: last, store: store, draft: draft)
    }
    await fulfillment(of: [joined])
    XCTAssertEqual(draft.text.string, "Edição após restaurar")
    let earlier = store.messages[0]
    let projected = expectation(description: "Earlier boundary projected")
    let second = Task {
      projected.fulfill()
      await store.reversion.perform(target: earlier, store: store, draft: draft)
    }
    await fulfillment(of: [projected], timeout: 5)
    XCTAssertEqual(draft.text.string, "Primeira mensagem")
    draft.text = NSAttributedString(string: "Edição enquanto aguarda")
    await server.release()
    await first.value
    await duplicate.value
    await second.value
    XCTAssertEqual(draft.text.string, "Edição enquanto aguarda")
    XCTAssertEqual(store.reversion.boundary(store.session), earlier.id)
    let staged = await server.staged
    XCTAssertEqual(staged, [last.id, earlier.id])
    XCTAssertFalse(store.reversion.pending)
    try await draft.discard()
  }
}

private actor RevertTestServer {
  private var gate: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  private var entered = false
  private var boundary: String?
  private(set) var staged: [String] = []
  func waitForStage() async {
    if entered { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func release() { gate?.resume(); gate = nil }
  func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = request.url!
    let text: String
    switch url.path {
    case "/api/info": text = #"{"version":"2.0.0"}"#
    case "/api/session/root":
      text = #"{"data":{"id":"root","projectID":"global","location":{"directory":"/fake"},"time":{"created":1,"updated":1}"#
        + (boundary.map { #", "revert":{"messageID":""# + $0 + #""}"# } ?? "") + "}}"
    case "/api/rpc/custom.transcript/list":
      text = #"{"output":{"data":[{"id":"msg_c","type":"user","text":"Última mensagem","time":{"created":3}},{"id":"msg_a","type":"user","text":"Primeira mensagem","time":{"created":1}}],"cursor":{}}}"#
    case "/api/session/active": text = #"{"data":{}}"#
    case "/api/session/root/inbox": text = #"{"data":[]}"#
    case "/api/rpc/custom.preferences/get":
      text = #"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#
    case "/api/rpc/custom.worktrees/available": text = #"{"output":false}"#
    case "/api/rpc/custom.session-family/revert": text = #"{"output":[]}"#
    case "/api/session/root/revert/stage":
      let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
      let id = body.object!["messageID"]!.string!
      staged.append(id)
      if !entered {
        await withCheckedContinuation { continuation in
          gate = continuation
          entered = true
          waiter?.resume()
          waiter = nil
        }
      }
      boundary = id
      text = "{}"
    default: text = "{}"
    }
    return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
