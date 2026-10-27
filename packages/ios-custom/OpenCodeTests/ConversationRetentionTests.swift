import XCTest

@testable import OpenCode
@testable import OpenCodeKit

/// Serves one Session whose tail can be replaced between reads, counting what the store asks for.
private actor RetainedReads {
  private var tail: [String] = ["msg_a", "msg_b"]
  private var history: [String: [String]] = [:]
  private(set) var olderReads = 0
  func setTail(_ ids: [String], history: [String: [String]] = [:]) {
    tail = ids
    self.history = history
  }
  func response(_ request: URLRequest) async -> (Data, URLResponse) {
    let path = request.url!.path
    let body: String
    switch path {
    case "/api/info": body = #"{"version":"test"}"#
    case "/api/session/ses_keep":
      body = #"{"data":{"id":"ses_keep","projectID":"global","location":{"directory":"/sandbox"},"time":{"created":1,"updated":3}}}"#
    case "/api/rpc/custom.transcript/list":
      let input = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody!))?.object?["input"]?.object
      let cursor = input?["cursor"]?.string
      if cursor != nil { olderReads += 1 }
      let ids = cursor.map { history[$0] ?? [] } ?? tail
      // Pages are newest first; each one points at the next older page by its oldest message.
      let data = ids.reversed().map { #"{"id":"\#($0)","type":"user","time":{"created":1},"text":"\#($0)"}"# }
      let next = ids.first.map { #"{"next":"\#($0)"}"# } ?? "{}"
      body = #"{"output":{"data":[\#(data.joined(separator: ","))],"cursor":\#(next)}}"#
    case "/api/session/active": body = #"{"data":{}}"#
    case "/api/session/ses_keep/inbox", "/api/model", "/api/agent", "/api/provider", "/api/shell":
      body = #"{"data":[]}"#
    case "/api/model/default": body = #"{"data":null}"#
    case "/api/rpc/custom.preferences/get":
      body = #"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#
    case "/api/rpc/custom.worktrees/available": body = #"{"output":true}"#
    case "/api/rpc/custom.worktrees/locate": body = #"{"output":[]}"#
    case "/api/rpc/custom.session-family/page": body = #"{"output":{"data":[]}}"#
    case "/api/rpc/custom.session-family/snapshot":
      body = #"{"output":{"count":0,"cost":0,"active":[],"forms":[],"permissions":[]}}"#
    default:
      XCTFail("Unexpected read: \(path)")
      body = "{}"
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class ConversationRetentionTests: XCTestCase {
  private func store(_ reads: RetainedReads) -> ConversationStore {
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
      await reads.response($0)
    }
    return ConversationStore(id: "ses_keep", client: client, hub: EventHub(client: client))
  }

  func testUnchangedRefreshPublishesNoRevision() async {
    let reads = RetainedReads()
    let store = store(reads)
    await store.refresh()
    XCTAssertTrue(store.ready)
    let revision = store.revision
    await store.refresh()
    XCTAssertEqual(store.revision, revision, "a return or reconnection with nothing new must not republish")
    await reads.setTail(["msg_a", "msg_b", "msg_c"])
    await store.refresh()
    XCTAssertEqual(store.revision, revision + 1)
    XCTAssertEqual(store.messages.map(\.id), ["msg_a", "msg_b", "msg_c"])
  }

  func testRetainedConversationReadsBackToItsHistoryInsteadOfLeavingAGap() async {
    let reads = RetainedReads()
    let store = store(reads)
    await store.refresh()
    // While away, more than a page arrived: the new tail no longer touches the loaded messages.
    await reads.setTail(["msg_e", "msg_f"], history: ["msg_e": ["msg_b", "msg_c", "msg_d"]])
    await store.refresh()
    XCTAssertEqual(store.messages.map(\.id), ["msg_a", "msg_b", "msg_c", "msg_d", "msg_e", "msg_f"])
    let older = await reads.olderReads
    XCTAssertEqual(older, 1)
  }

  func testRetainedConversationStartsAgainFromTheTailBeyondFivePages() async {
    let reads = RetainedReads()
    let store = store(reads)
    await store.refresh()
    var history: [String: [String]] = [:]
    for page in 0..<6 { history["msg_p\(page + 1)"] = ["msg_p\(page)"] }
    await reads.setTail(["msg_p6"], history: history)
    await store.refresh()
    XCTAssertFalse(store.messages.contains { $0.id == "msg_a" })
    XCTAssertEqual(store.messages.last?.id, "msg_p6")
    XCTAssertTrue(store.hasOlder)
  }

  func testRegistryKeepsRecentConversationsAndTheStack() {
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { request in
      (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
    let hub = EventHub(client: client)
    let registry = ConversationRegistry(capacity: 2)
    var stack: Set<String> = ["ses_root"]
    registry.stack = { stack }
    func open(_ id: String) -> ConversationStore {
      registry.store(id) { ConversationStore(id: id, client: client, hub: hub) }
    }
    let root = open("ses_root")
    let first = open("ses_1")
    XCTAssertTrue(open("ses_1") === first, "returning finds the same conversation")
    _ = open("ses_2")
    _ = open("ses_3")
    XCTAssertTrue(registry.existing("ses_root") === root, "a conversation on the stack is never released")
    XCTAssertNil(registry.existing("ses_1"), "the least recent one beyond capacity goes")
    XCTAssertNotNil(registry.existing("ses_3"))
    root.memory.setOutput("tool", value: "output")
    root.memory.setBubble("msg", expanded: true)
    stack = ["ses_root"]
    registry.releaseMemory()
    XCTAssertNil(registry.existing("ses_3"))
    XCTAssertTrue(registry.existing("ses_root") === root)
    XCTAssertNil(root.memory.output("tool"), "fetched output can be read again")
    XCTAssertTrue(root.memory.bubble("msg"), "the reader's own choices stay")
  }

  func testLatestParseNeverStarvesDuringAFastStream() async throws {
    let parser = LatestMarkdownParse(interval: .milliseconds(50))
    var published: [String] = []
    parser.publish = { blocks, _, _ in published.append(blocks.map(\.text).joined()) }
    var text = ""
    let theme = AppTheme.load("openchamber-dark")
    let started = ContinuousClock.now
    // A newer text arrives before every parse lands, for much longer than the publishing interval.
    var index = 0
    while started.duration(to: .now) < .milliseconds(400) {
      text += " palavra\(index)"
      index += 1
      parser.request(text, theme: theme, scale: 2)
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertFalse(published.isEmpty, "an uninterrupted stream still publishes")
    for _ in 0..<200 where published.last != text.trimmingCharacters(in: .whitespaces) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(published.last, text.trimmingCharacters(in: .whitespaces))
    XCTAssertLessThan(published.count, index, "texts that arrived during a parse are skipped")
    XCTAssertEqual(published, published.sorted { $0.count < $1.count }, "results never go back in time")
  }
}
