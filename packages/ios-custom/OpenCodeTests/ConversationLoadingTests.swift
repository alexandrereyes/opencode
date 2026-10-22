import XCTest

@testable import OpenCode
@testable import OpenCodeKit

private actor CatalogGate {
  private var entered = false
  private var released = false
  private var arrivals: [CheckedContinuation<Void, Never>] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func waitForArrival() async {
    if entered { return }
    await withCheckedContinuation { arrivals.append($0) }
  }
  func enter() async {
    entered = true
    arrivals.forEach { $0.resume() }
    arrivals.removeAll()
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

private actor OpeningReadProbe {
  let gate = CatalogGate()
  let failsFamily: Bool
  private var running: Bool
  private var tails = 0
  init(failsFamily: Bool = false, running: Bool = false) {
    self.failsFamily = failsFamily
    self.running = running
  }
  func finishExecution() { running = false }

  func response(_ request: URLRequest) async -> (Data, URLResponse) {
    let path = request.url!.path
    if path == "/api/model" { await gate.enter() }
    let body: String
    switch path {
    case "/api/info": body = #"{"version":"test"}"#
    case "/api/session/ses_open":
      body = #"{"data":{"id":"ses_open","projectID":"global","location":{"directory":"/sandbox"},"time":{"created":1,"updated":3,"viewed":1}}}"#
    case "/api/rpc/custom.transcript/list":
      let input = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody!))?.object?["input"]?.object
      if input?["cursor"]?.string == "older" {
        body = #"{"output":{"data":[{"id":"msg_old","type":"user","time":{"created":1},"text":"Histórico"}],"cursor":{}}}"#
        break
      }
      tails += 1
      body = """
        {"output":{"data":[{"id":"msg_tail","type":"assistant","time":{"created":2,"completed":3},
        "content":[{"type":"text","text":"Resposta \(tails)"}]}],"cursor":{"next":"older"}}}
        """
    case "/api/session/active":
      body = running ? #"{"data":{"ses_open":{"type":"running"}}}"# : #"{"data":{}}"#
    case "/api/session/ses_open/inbox", "/api/model", "/api/agent", "/api/provider", "/api/shell":
      body = #"{"data":[]}"#
    case "/api/model/default": body = #"{"data":null}"#
    case "/api/rpc/custom.preferences/get":
      body = #"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#
    case "/api/rpc/custom.worktrees/available": body = #"{"output":true}"#
    case "/api/rpc/custom.worktrees/locate": body = #"{"output":[]}"#
    case "/api/rpc/custom.session-family/page": body = #"{"output":{"data":[]}}"#
    case "/api/rpc/custom.session-family/snapshot":
      body = failsFamily ? #"{"_tag":"RpcError","type":"read_failed"}"#
        : #"{"output":{"count":0,"cost":0,"active":[],"forms":[],"permissions":[]}}"#
    default:
      XCTFail("Unexpected read: \(path)")
      body = "{}"
    }
    return (Data(body.utf8), HTTPURLResponse(url: request.url!,
      statusCode: failsFamily && path.hasSuffix("/snapshot") ? 400 : 200,
      httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class ConversationLoadingTests: XCTestCase {
  func testTailPublishesBeforeCatalogsAndDoesNotDiscardConcurrentOlderPage() async throws {
    let probe = OpeningReadProbe(running: true)
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
      await probe.response($0)
    }
    let store = ConversationStore(id: "ses_open", client: client, hub: EventHub(client: client))
    let loading = Task { await store.refresh() }
    await probe.gate.waitForArrival()
    XCTAssertTrue(store.hasTranscript)
    XCTAssertFalse(store.loading)
    XCTAssertFalse(store.ready)
    XCTAssertTrue(store.executing)
    XCTAssertEqual(store.messages.map(\.id), ["msg_tail"])
    await store.older()
    XCTAssertEqual(store.messages.map(\.id), ["msg_old", "msg_tail"])
    await probe.gate.release()
    await loading.value
    XCTAssertNil(store.error)
    XCTAssertTrue(store.ready)
    XCTAssertTrue(store.executing)
    XCTAssertEqual(store.messages.map(\.id), ["msg_old", "msg_tail"])
    await probe.finishExecution()
    await store.refresh()
    XCTAssertFalse(store.executing)
    XCTAssertEqual(store.messages.map(\.id), ["msg_old", "msg_tail"])
    XCTAssertEqual(store.messages.last?.responseText, "Resposta 2")
    XCTAssertFalse(store.hasOlder)
  }

  func testRuntimeFailureKeepsPublishedHistory() async throws {
    let probe = OpeningReadProbe(failsFamily: true)
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
      await probe.response($0)
    }
    let store = ConversationStore(id: "ses_open", client: client, hub: EventHub(client: client))
    let loading = Task { await store.refresh() }
    await probe.gate.waitForArrival()
    await probe.gate.release()
    await loading.value
    XCTAssertTrue(store.hasTranscript)
    XCTAssertFalse(store.loading)
    XCTAssertFalse(store.ready)
    XCTAssertEqual(store.messages.map(\.id), ["msg_tail"])
    XCTAssertNotNil(store.error)
  }

  func testCancelledRuntimeDoesNotBecomeReadyAfterLateCatalogResponse() async throws {
    let probe = OpeningReadProbe()
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
      await probe.response($0)
    }
    let store = ConversationStore(id: "ses_open", client: client, hub: EventHub(client: client))
    let loading = Task { await store.refresh() }
    await probe.gate.waitForArrival()
    loading.cancel()
    await probe.gate.release()
    await loading.value
    XCTAssertTrue(store.hasTranscript)
    XCTAssertFalse(store.ready)
    XCTAssertFalse(store.loading)
    XCTAssertNil(store.error)
    XCTAssertEqual(store.messages.map(\.id), ["msg_tail"])
  }
}
