import Foundation
import XCTest

@testable import OpenCode
@testable import OpenCodeKit

private actor MCPTestHTTP {
  var requests: [URLRequest] = []
  var servers = [MCPServer(name: "safari-devtools", state: .connected),
    MCPServer(name: "codex-computer-use", state: .disabled),
    MCPServer(name: "auth", state: .needsAuth)]
  let failure: Int?
  let rejectsMutation: Bool
  var mutation: CheckedContinuation<Void, Never>?
  var admission: CheckedContinuation<Void, Never>?
  init(failure: Int? = nil, rejectsMutation: Bool = false) {
    self.failure = failure
    self.rejectsMutation = rejectsMutation
  }
  func waitForMutation() async {
    if mutation != nil { return }
    await withCheckedContinuation { admission = $0 }
  }
  func finish() { mutation?.resume(); mutation = nil }
  func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let post = request.httpMethod == "POST"
    if post {
      await withCheckedContinuation { mutation = $0; admission?.resume(); admission = nil }
      if !rejectsMutation {
        servers = servers.map { $0.name == "safari-devtools" ? .init(name: $0.name, state: request.url!.path.hasSuffix("/disconnect") ? .disabled : .connected) : $0 }
      }
    }
    return (try JSONEncoder().encode(["data": servers]),
      HTTPURLResponse(url: request.url!, statusCode: failure ?? (post ? (rejectsMutation ? 503 : 204) : 200), httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class ConversationMCPTests: XCTestCase {
  func testLazyLocationPendingConfirmationStableOrderAndReopen() async throws {
    let http = MCPTestHTTP()
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) {
      try await http.respond($0)
    }
    let toast = ToastCenter()
    let store = ConversationMCPStore(client: client, toast: toast)
    XCTAssertFalse(store.summary.visible)
    let initial = await http.requests
    XCTAssertTrue(initial.isEmpty)
    await store.load(directory: "/child with space")
    store.open()
    let original = store.chips.map(\.name)
    let safari = try XCTUnwrap(store.chips.first)
    let task = Task { await store.toggle(safari) }
    await http.waitForMutation()
    XCTAssertEqual(store.chips.first?.status.status, .pending)
    await store.toggle(safari)
    await http.finish()
    await task.value
    XCTAssertEqual(store.chips.first?.status.status, .disabled)
    XCTAssertEqual(store.chips.map(\.name), original)
    XCTAssertEqual(store.summary.connected, 0)
    store.close()
    store.open()
    XCTAssertEqual(store.chips.map(\.name), ["codex-computer-use", "safari-devtools", "auth"])
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    XCTAssertTrue(requests.allSatisfy {
      URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "location[directory]", value: "/child with space")]
    })
    XCTAssertNil(toast.message)
  }
  func testLoginDoesNotRequestOAuthAndUnsupportedIsSilent() async throws {
    let http = MCPTestHTTP()
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { try await http.respond($0) }
    let toast = ToastCenter()
    let store = ConversationMCPStore(client: client, toast: toast)
    await store.load(directory: "/chat")
    await store.toggle(try XCTUnwrap(store.chips.first { $0.name == "auth" }))
    XCTAssertTrue(toast.message?.text.contains("app web") == true)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    let unsupported = MCPTestHTTP(failure: 404)
    let old = ConversationMCPStore(client: OpenCodeClient(configuration: client.configuration) {
      try await unsupported.respond($0)
    }, toast: ToastCenter())
    await old.load(directory: "/master")
    XCTAssertFalse(old.summary.visible)
    XCTAssertTrue(old.unsupported)
    XCTAssertFalse(old.isOpen)
  }
  func testMutationFailureRestoresServerStateAndKeepsOrderWithExistingToast() async throws {
    let http = MCPTestHTTP(rejectsMutation: true)
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { try await http.respond($0) }
    let toast = ToastCenter()
    let store = ConversationMCPStore(client: client, toast: toast)
    await store.load(directory: "/child")
    store.open()
    let order = store.chips.map(\.name)
    let task = Task { await store.toggle(store.chips[0]) }
    await http.waitForMutation()
    await http.finish()
    await task.value
    XCTAssertEqual(store.chips.map(\.name), order)
    XCTAssertEqual(store.chips.first?.status.status, .connected)
    XCTAssertTrue(store.toggling.isEmpty)
    XCTAssertTrue(toast.message?.text.contains("Não foi possível alterar safari-devtools") == true)
  }
}
