import Foundation
import XCTest
@testable import OpenCode
@testable import OpenCodeKit

private actor VoiceMasterHTTP {
  var requests: [URLRequest] = []
  var masterID: String?
  var promptID: String?
  var deleted: Set<String> = []
  var created = 0
  var uploads: [(URL, Data)] = []
  var ensureVoice: [Bool?] = []
  /// Prompts answered 503 before one goes through, like a WARP route that drops for a moment.
  var promptFailures: Int
  var promptIDs: [String?] = []
  init(masterID: String? = nil, promptFailures: Int = 0) { self.masterID = masterID; self.promptFailures = promptFailures }
  func delete(_ id: String) { deleted.insert(id) }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    let path = request.url!.path
    let input = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    let value: JSONValue
    var status = 200
    switch path {
    case "/api/rpc/custom.master/info":
      value = .object(["output": .object(["version": .number(1), "agent": .string("mestra"), "model": model])])
    case "/api/rpc/custom.preferences/get":
      value = .object(["output": preferences])
    case "/api/rpc/custom.master/ensure":
      ensureVoice.append(input?.object?["input"]?.object?["voice"]?.bool)
      // Mirrors the plugin: keep a live pointer, otherwise create and point to a new master.
      let reused = masterID.map { !deleted.contains($0) } ?? false
      if !reused { created += 1; masterID = "ses_ensured\(created)" }
      value = .object(["output": .object(["sessionID": .string(masterID!), "directory": .string("/fake/chat"),
        "created": .bool(!reused), "preferences": preferences])])
    case "/api/rpc/custom.chats/info": value = .object(["output": .object(["root": .string("/fake")])])
    case "/api/model/default": value = .object(["data": .null])
    case "/api/session/active": value = .object(["data": .object([:])])
    case "/api/info": value = .object(["version": .string("0.0.0-test"), "paths": .object(["tmp": .string("/fake/tmp")])])
    case "/api/model":
      value = .object(["data": .array([.object(["id": .string("fake"), "providerID": .string("fake"), "name": .string("Fake"),
        "limit": .object(["context": .number(1000)]),
        "capabilities": .object(["input": .array([.string("text"), .string("image")])])])])])
    case "/api/experimental/fs/write": uploads.append((request.url!, request.httpBody ?? Data())); value = .object([:])
    case "/api/rpc/custom.transcript/list":
      value = .object(["output": .object(["data": .array([
        .object(["id": .string("answer"), "type": .string("assistant"),
          "time": .object(["created": .number(0), "completed": .number(1)]),
          "content": .array([.object(["type": .string("text"), "text": .string("Resposta final confirmada.")])])]),
        .object(["id": .string(promptID ?? "missing"), "type": .string("user"), "time": .object(["created": .number(0)])]),
      ])])])
    default:
      if let id = masterID, deleted.contains(id), path.hasPrefix("/api/session/\(id)") {
        status = 404; value = .object(["_tag": .string("SessionNotFoundError")])
      } else if path.hasSuffix("/prompt") {
        promptID = input?.object?["id"]?.string
        promptIDs.append(promptID)
        status = promptFailures > 0 ? 503 : 200; value = .object([:])
        promptFailures -= 1
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
  private var preferences: JSONValue {
    .object(["revision": .number(1), "data": .object([
      "projects": .object([:]), "pinnedSessions": .array([]), "settings": .object(["autoApprove": .bool(false)]),
      "masterSessions": .object(masterID.map { ["local": .string($0)] } ?? [:]),
    ])])
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
    XCTAssertEqual(requests.filter { $0.url?.path == "/api/rpc/custom.master/ensure" }.count, 1)
    // The call's first delegation turns on the master's voice-call note.
    let voice = await http.ensureVoice
    XCTAssertEqual(voice, [true])
    let created = await http.created
    XCTAssertEqual(created, 1)
    let prompts = try requests.filter { $0.url!.path.hasSuffix("/prompt") }.map {
      try JSONDecoder().decode(PromptRequest.self, from: XCTUnwrap($0.httpBody))
    }
    XCTAssertEqual(prompts.map(\.delivery), [.steer, .queue])
    XCTAssertEqual(prompts.map(\.text), ["Primeiro pedido", "Segundo pedido"])
    XCTAssertEqual(updates.count, 2)
    // Admission is shown, never spoken: GPT Live acknowledges the request itself.
    for update in updates {
      guard case .progress(_, let narrate) = update else { return XCTFail("Missing admission") }
      XCTAssertFalse(narrate)
    }
    let failedTool = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"session.tool.failed","data":{"sessionID":"\(firstID!)"}}
      """.utf8))
    await master.receive(failedTool)
    guard case .progress(_, let narrateFailure) = updates.last else { return XCTFail("Missing tool failure") }
    XCTAssertFalse(narrateFailure)
    let text = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"session.text.ended","data":{"sessionID":"\(firstID!)","text":"Achei duas sessões."}}
      """.utf8))
    await master.receive(text)
    guard case .progress(let update, let narrateText) = updates.last else { return XCTFail("Missing text update") }
    XCTAssertEqual(update, "Atualização: Achei duas sessões.")
    XCTAssertTrue(narrateText)
    let event = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"session.tool.called","data":{"sessionID":"\(firstID!)","name":"sessions.read"}}
      """.utf8))
    await master.receive(event)
    guard case .progress(let message, let narrate) = updates.last else { return XCTFail("Missing progress") }
    XCTAssertEqual(message, "A mestra está conferindo uma sessão.")
    XCTAssertFalse(narrate)
    let attention = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"permission.asked","data":{"sessionID":"\(firstID!)"}}
      """.utf8))
    await master.receive(attention)
    guard case .progress(_, let narrateAttention) = updates.last else { return XCTFail("Missing attention") }
    XCTAssertTrue(narrateAttention)
    let completed = try JSONDecoder().decode(ConversationEvent.self, from: Data("""
      {"type":"session.execution.succeeded","data":{"sessionID":"\(firstID!)"}}
      """.utf8))
    await master.receive(completed)
    guard case .finished(let result) = updates.last else { return XCTFail("Missing final answer") }
    XCTAssertEqual(result, "Resposta final confirmada.")
    master.stop()
  }
  func testScreenGoesToTheMasterAsTheComposerImageAttachment() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_existing")
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    let master = VoiceMaster(sessions: SessionStore(configuration: config, client: client)) { _ in }
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9])
    try await master.ask(VoiceMasterRequest(#"{"text":"Dá uma olhada nessa tela","screen":true}"#),
      screen: VoiceScreenShot(jpeg: jpeg, sessionID: "ses_aberta"))
    let uploads = await http.uploads
    XCTAssertEqual(uploads.count, 1)
    XCTAssertEqual(uploads.first?.1, jpeg)
    let target = try XCTUnwrap(URLComponents(url: XCTUnwrap(uploads.first?.0), resolvingAgainstBaseURL: false))
    XCTAssertTrue(target.queryItems?.first { $0.name == "path" }?.value?.hasPrefix("/fake/tmp/uploads/") == true)
    XCTAssertTrue(target.queryItems?.first { $0.name == "path" }?.value?.hasSuffix("/tela-opencode.jpg") == true)
    XCTAssertEqual(target.queryItems?.first { $0.name == "location[directory]" }?.value, "/fake/chat")
    let requests = await http.requests
    let body = try XCTUnwrap(requests.first { $0.url!.path.hasSuffix("/prompt") }?.httpBody)
    let prompt = try JSONDecoder().decode(JSONValue.self, from: body).object
    let text = try XCTUnwrap(prompt?["text"]?.string)
    XCTAssertTrue(text.hasPrefix("Dá uma olhada nessa tela\n\n[Captura da tela do app OpenCode anexada. Sessão aberta no app: ses_aberta]"))
    let file = try XCTUnwrap(prompt?["files"]?.array?.first?.object)
    XCTAssertEqual(file["name"]?.string, "tela-opencode.jpg")
    XCTAssertEqual(file["uri"]?.string, "data:image/jpeg;base64," + jpeg.base64EncodedString())
    XCTAssertEqual(prompt?["metadata"]?.object?["agent"]?.string, "mestra")
    master.stop()
  }
  func testDelegationWithoutScreenUploadsNothing() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_existing")
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    let master = VoiceMaster(sessions: SessionStore(configuration: config, client: client)) { _ in }
    try await master.ask(VoiceMasterRequest("Só texto"))
    let uploads = await http.uploads
    XCTAssertTrue(uploads.isEmpty)
    let requests = await http.requests
    let body = try XCTUnwrap(requests.first { $0.url!.path.hasSuffix("/prompt") }?.httpBody)
    let prompt = try JSONDecoder().decode(JSONValue.self, from: body).object
    XCTAssertEqual(prompt?["text"]?.string, "Só texto")
    XCTAssertNil(prompt?["files"])
    master.stop()
  }
  func testMasterDeletedDuringCallIsReplacedOnce() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_existing")
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    let sessions = SessionStore(configuration: config, client: client)
    let master = VoiceMaster(sessions: sessions) { _ in }
    try await master.ask(VoiceMasterRequest("Antes"))
    XCTAssertEqual(sessions.masterID, "ses_existing")
    await http.delete("ses_existing")
    try await master.ask(VoiceMasterRequest("Depois"))
    XCTAssertEqual(sessions.masterID, "ses_ensured1")
    let prompts = await http.requests.compactMap { $0.url?.path }.filter { $0.hasSuffix("/prompt") }
    XCTAssertEqual(prompts, ["/api/session/ses_existing/prompt", "/api/session/ses_ensured1/prompt"])
    master.stop()
  }
  func testOpeningDeletedMasterRecreatesIt() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_deleted")
    await http.delete("ses_deleted")
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    let sessions = SessionStore(configuration: config, client: client)
    await sessions.loadMaster()
    sessions.adoptMaster(try await client.preferences())
    XCTAssertEqual(sessions.masterID, "ses_deleted")
    await sessions.verifyMaster()
    XCTAssertEqual(sessions.masterID, "ses_ensured1")
    await sessions.verifyMaster()
    let ensures = await http.requests.filter { $0.url?.path == "/api/rpc/custom.master/ensure" }.count
    XCTAssertEqual(ensures, 1)
  }
  func testFailedAdmissionNeverAnnouncesSuccess() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_existing", promptFailures: .max)
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    var updates: [VoiceMasterUpdate] = []
    let master = VoiceMaster(sessions: SessionStore(configuration: config, client: client), retry: [0.01, 0.01]) { updates.append($0) }
    do { try await master.ask(VoiceMasterRequest("Teste")); XCTFail("Expected failure") } catch {}
    XCTAssertTrue(updates.isEmpty)
    let attempts = await http.promptIDs
    XCTAssertEqual(attempts.count, 3, "two retries, then the failure")
    master.stop()
  }
  /// A blip during admission: the retry carries the same prompt ID, which the server admits once.
  func testAdmissionRetriesAfterABlipWithTheSamePromptID() async throws {
    let http = VoiceMasterHTTP(masterID: "ses_existing", promptFailures: 2)
    let config = ServerConfiguration(url: URL(string: "http://127.0.0.1:4177")!)
    let client = OpenCodeClient(configuration: config) { try await http.respond($0) }
    var updates: [VoiceMasterUpdate] = []
    let master = VoiceMaster(sessions: SessionStore(configuration: config, client: client), retry: [0.01, 0.01, 0.01]) {
      updates.append($0)
    }
    try await master.ask(VoiceMasterRequest("Pesquise na web"))
    let attempts = await http.promptIDs
    XCTAssertEqual(attempts.count, 3)
    XCTAssertEqual(Set(attempts.compactMap { $0 }).count, 1)
    guard case .progress(_, narrate: false) = updates.last else { return XCTFail("Missing admission") }
    master.stop()
  }
}
