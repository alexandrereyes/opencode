import Foundation
import XCTest
@testable import OpenCode
@testable import OpenCodeKit

private actor VoiceMasterHTTP {
  var requests: [URLRequest] = []
  var masterID: String?
  var promptID: String?
  let failsPrompt: Bool
  init(masterID: String? = nil, failsPrompt: Bool = false) { self.masterID = masterID; self.failsPrompt = failsPrompt }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    let path = request.url!.path
    let input = try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
    let value: JSONValue
    var status = 200
    switch path {
    case "/api/rpc/custom.master/info":
      value = .object(["output": .object(["version": .number(1), "agent": .string("mestra"), "model": model])])
    case "/api/rpc/custom.preferences/get", "/api/rpc/custom.preferences/mutate":
      if path.hasSuffix("mutate") { masterID = input?.object?["input"]?.object?["sessionID"]?.string }
      value = .object(["output": .object(["revision": .number(1), "data": .object([
        "projects": .object([:]), "pinnedSessions": .array([]), "settings": .object(["autoApprove": .bool(false)]),
        "masterSessions": .object(masterID.map { ["local": .string($0)] } ?? [:]),
      ])])])
    case "/api/rpc/custom.chats/allocate":
      value = .object(["output": .object(["id": .string("allocation"), "directory": .string("/fake/chat")])])
    case "/api/rpc/custom.chats/claim", "/api/rpc/custom.chats/confirm": value = .object(["output": .object([:])])
    case "/api/session": masterID = input?.object?["id"]?.string; value = .object([:])
    case "/api/session/active": value = .object(["data": .object([:])])
    case "/api/rpc/custom.transcript/list":
      value = .object(["output": .object(["data": .array([
        .object(["id": .string("answer"), "type": .string("assistant"),
          "time": .object(["created": .number(0), "completed": .number(1)]),
          "content": .array([.object(["type": .string("text"), "text": .string("Resposta final confirmada.")])])]),
        .object(["id": .string(promptID ?? "missing"), "type": .string("user"), "time": .object(["created": .number(0)])]),
      ])])])
    default:
      if path.hasSuffix("/prompt") {
        promptID = input?.object?["id"]?.string
        status = failsPrompt ? 503 : 200; value = .object([:])
      } else if path.hasSuffix("/inbox") {
        value = .object(["data": .array([])])
      } else if path == "/api/session/\(masterID ?? "missing")" {
        value = .object(["data": .object(["id": .string(masterID!), "projectID": .string("global"),
          "location": .object(["directory": .string("/fake/chat")]), "agent": .string("mestra"),
          "model": model, "time": .object(["created": .number(0), "updated": .number(0)])])])
      } else { throw ClientError.operation("Unexpected test request") }
    }
    return (try JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
  private var model: JSONValue { .object(["id": .string("fake"), "providerID": .string("fake")]) }
}

@MainActor final class VoiceMasterTests: XCTestCase {
  func testMissingMasterAllocatedOnlyAtAskAndFollowupReusesIt() async throws {
    let http = VoiceMasterHTTP()
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: configuration) { try await http.respond($0) }
    let sessions = SessionStore(configuration: configuration, client: client)
    var updates: [VoiceMasterUpdate] = []
    let master = VoiceMaster(sessions: sessions) { updates.append($0) }
    let initial = await http.requests
    XCTAssertTrue(initial.isEmpty)
    try await master.ask(VoiceMasterRequest("Primeiro pedido"))
    let firstID = sessions.masterID
    XCTAssertNotNil(firstID)
    try await master.ask(VoiceMasterRequest(#"{"text":"Segundo pedido","delivery":"queue"}"#))
    XCTAssertEqual(sessions.masterID, firstID)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.url?.path == "/api/rpc/custom.chats/allocate" }.count, 1)
    XCTAssertEqual(requests.filter { $0.url?.path == "/api/session" }.count, 1)
    let prompts = try requests.filter { $0.url!.path.hasSuffix("/prompt") }.map {
      try JSONDecoder().decode(PromptRequest.self, from: XCTUnwrap($0.httpBody))
    }
    XCTAssertEqual(prompts.map(\.delivery), [.steer, .queue])
    XCTAssertEqual(prompts.map(\.text), ["Primeiro pedido", "Segundo pedido"])
    XCTAssertEqual(updates.count, 2)
    let event = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"session.tool.called","data":{"sessionID":"\(firstID!)","name":"session_read"}}
      """.utf8))
    await master.receive(event)
    guard case .progress(let message) = updates.last else { return XCTFail("Missing progress") }
    XCTAssertEqual(message, "A mestra está conferindo uma sessão.")
    let completed = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"session.execution.succeeded","data":{"sessionID":"\(firstID!)"}}
      """.utf8))
    await master.receive(completed)
    guard case .finished(let result) = updates.last else { return XCTFail("Missing final answer") }
    XCTAssertEqual(result, "Resposta final confirmada.")
    master.stop()
  }
  func testFailedAdmissionNeverAnnouncesSuccess() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_existing", failsPrompt: true)
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    var updates: [VoiceMasterUpdate] = []
    let master = VoiceMaster(sessions: SessionStore(configuration: config, client: client)) { updates.append($0) }
    do { try await master.ask(VoiceMasterRequest("Teste")); XCTFail("Expected failure") } catch {}
    XCTAssertTrue(updates.isEmpty)
    master.stop()
  }
}
