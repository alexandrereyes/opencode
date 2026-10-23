import Foundation
import XCTest
@testable import OpenCode
@testable import OpenCodeKit

@MainActor private final class VoiceTestTransport: VoiceTransporting {
  var event: (@MainActor @Sendable (VoiceTransportEvent) -> Void)?
  var muted = false
  var closed = false
  var frames: [Data] = []
  var answered: (() -> Void)?
  func offer() async throws -> String { "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" }
  func answer(_ sdp: String) async throws {
    event?(.connected); event?(.data(Data(#"{"type":"session.started"}"#.utf8))); answered?()
  }
  func send(_ data: Data) async throws { frames.append(data) }
  func mute(_ muted: Bool) { self.muted = muted }
  func resume() { event?(.resumed) }
  func close() async { closed = true }
}

@MainActor private final class VoiceTestMaster: VoiceMasterServing {
  var requests: [VoiceMasterRequest] = []
  var update: ((VoiceMasterUpdate) -> Void)?
  var asked: (() -> Void)?
  var stopped = false
  func ask(_ request: VoiceMasterRequest) async throws {
    requests.append(request); update?(.progress("Consultando a sessão de teste.")); asked?()
  }
  func stop() { stopped = true }
}

private actor VoiceTestHTTP {
  var requests: [URLRequest] = []
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    if request.url!.path.hasSuffix("/calls") {
      return (Data("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n".utf8),
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Location": "/v1/live/test"])!)
    }
    if request.httpMethod == "DELETE" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!) }
    let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
    let formatter = ISO8601DateFormatter()
    return (try JSONEncoder().encode(["sessionId": request.url!.lastPathComponent,
      "generation": body["generation"]!, "serverTime": formatter.string(from: .now),
      "leaseExpiresAt": formatter.string(from: .now.addingTimeInterval(60))]),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class VoiceControllerTests: XCTestCase {
  func testReadinessMuteInterruptionAndStaleCallbacks() async throws {
    let transport = VoiceTestTransport()
    let master = VoiceTestMaster()
    let http = VoiceTestHTTP()
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { update in master.update = update; return master }, request: { try await http.respond($0) }))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    XCTAssertEqual(controller.state.phase, .listening)
    controller.mute(); XCTAssertTrue(transport.muted)
    transport.event?(.interrupted); XCTAssertEqual(controller.state.phase, .interrupted)
    controller.resume(); XCTAssertEqual(controller.state.phase, .listening)
    transport.event?(.data(Data(#"{"type":"output_transcript.added","item":{"text":"Olá"}}"#.utf8)))
    XCTAssertEqual(controller.state.phase, .speaking)
    transport.event?(.data(Data(#"{"type":"input_transcript.added","item":{"text":"Pare"}}"#.utf8)))
    XCTAssertEqual(controller.state.phase, .listening)
    await controller.end()
    XCTAssertTrue(transport.closed); XCTAssertTrue(master.stopped)
    transport.event?(.connected)
    XCTAssertEqual(controller.state.phase, .idle)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/calls") == true }.count, 1)
    XCTAssertEqual(requests.last?.httpMethod, "DELETE")
  }
  func testDelegationReturnsBeforeMasterFinishesAndAcceptsFollowup() async throws {
    let transport = VoiceTestTransport()
    let master = VoiceTestMaster()
    let http = VoiceTestHTTP()
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { update in master.update = update; return master }, request: { try await http.respond($0) }))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    let first = expectation(description: "first")
    master.asked = { first.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"a","content":[{"type":"input_text","text":"Confira"}]}}"#.utf8)))
    await fulfillment(of: [first], timeout: 3)
    XCTAssertTrue(controller.state.masterWorking)
    XCTAssertTrue(controller.detail.contains("Consultando"))
    let followup = expectation(description: "followup")
    master.asked = { followup.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"b","content":[{"type":"input_text","text":"{\"text\":\"Depois\",\"delivery\":\"queue\"}"}]}}"#.utf8)))
    await fulfillment(of: [followup], timeout: 3)
    XCTAssertEqual(master.requests.map(\.delivery), [.steer, .queue])
    master.update?(.finished("Concluído"))
    XCTAssertFalse(controller.state.masterWorking)
    await controller.end()
  }
  func testPermissionDenialDoesNotReachProxy() async {
    let http = VoiceTestHTTP()
    let controller = VoiceController(testing: .init(transport: { _ in VoiceTestTransport() },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }, permission: false))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    for _ in 0..<100 where controller.state.phase != .failed { await Task.yield() }
    XCTAssertEqual(controller.state.phase, .failed)
    // Teardown may release an unused reservation, but never starts a provider call.
    let requests = await http.requests
    XCTAssertFalse(requests.contains { $0.httpMethod == "POST" })
    await controller.end()
  }
}
