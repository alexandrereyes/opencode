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

@MainActor private final class SilentLiveTransport: VoiceTransporting {
  private let transport: VoiceTransport
  init(event: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) { transport = VoiceTransport(event: event) }
  func offer() async throws -> String {
    let sdp = try await transport.offer()
    // The track exists now, but there is no remote answer/connection yet.
    // Disable it before returning the offer so no microphone audio can leave.
    transport.mute(true)
    return sdp
  }
  func answer(_ sdp: String) async throws { try await transport.answer(sdp) }
  func send(_ data: Data) async throws { try await transport.send(data) }
  func mute(_ muted: Bool) { transport.mute(true) }
  func resume() { transport.resume() }
  func close() async { await transport.close() }
}

private actor LiveMemoryHTTP {
  struct Metrics: Codable, Sendable {
    var creates = 0
    var statuses: [Int] = []
    var initialItems = 0
    var initialTokens = 0
    var roles: [String] = []
    var releases: [Int] = []
  }
  var metrics = Metrics()
  func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    if request.url?.path.hasSuffix("/calls") == true {
      metrics.creates += 1
      let value = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
      let items = value.object?["session"]?.object?["initial_items"]?.array ?? []
      metrics.initialItems = items.count
      metrics.roles = Array(Set(items.compactMap { $0.object?["role"]?.string })).sorted()
      metrics.initialTokens = items.reduce(0) { sum, item in
        sum + (item.object?["content"]?.array ?? []).reduce(0) { $0 + VoiceHistoryBudget.estimate($1.object?["text"]?.string ?? "") }
      }
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    if request.url?.path.hasSuffix("/calls") == true { metrics.statuses.append((response as? HTTPURLResponse)?.statusCode ?? 0) }
    if request.httpMethod == "DELETE" { metrics.releases.append((response as? HTTPURLResponse)?.statusCode ?? 0) }
    return (data, response)
  }
}

@MainActor private final class LiveReadiness {
  let expectation: XCTestExpectation
  var media = false
  var protocolReady = false
  var fulfilled = false
  init(_ expectation: XCTestExpectation) { self.expectation = expectation }
  func receive(_ event: VoiceTransportEvent) {
    if case .connected = event { media = true }
    if case .data(let data) = event, (try? VoiceProtocol.decode(data)) == .ready { protocolReady = true }
    if media && protocolReady && !fulfilled { fulfilled = true; expectation.fulfill() }
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

  func testCanonicalTurnsAreDurableAndInterruptedBeforeEndEvenOnAnOlderServer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/voice-controller-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4180")!)
    let client = OpenCodeClient(configuration: configuration, transport: { request in
      XCTAssertEqual(request.url?.lastPathComponent, "info")
      return (Data(#"{"output":{"version":1}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let memory = VoiceMemoryStore(client: client, root: root)
    let transport = VoiceTestTransport()
    let http = VoiceTestHTTP()
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }, memory: memory))
    controller.start(sessions: SessionStore(configuration: configuration))
    await fulfillment(of: [answered], timeout: 3)
    for json in [
      #"{"type":"output_transcript.added","item":{"id":"item-output","text":"Só um delta"}}"#,
      #"{"type":"input_transcript.added","item":{"id":"item-user","text":"Interrompi"}}"#,
      #"{"type":"turn.done","turn":{"id":"turn-output","role":"assistant","transcript":"Texto canônico completo, sem depender do delta."}}"#,
      #"{"type":"turn.done","turn":{"id":"turn-output","role":"assistant","transcript":"Não pode duplicar"}}"#,
    ] { transport.event?(.data(Data(json.utf8))) }
    transport.event?(.interrupted)
    transport.event?(.data(Data(#"{"type":"turn.done","turn":{"id":"turn-user","role":"user","transcript":"Minha fala completa."}}"#.utf8)))
    await controller.end()
    await memory.stop()
    let recovered = try await VoiceMemoryBuffer(server: configuration.url.absoluteString, root: root).snapshot()
    XCTAssertEqual(recovered.context.turns.map(\.text), ["Texto canônico completo, sem depender do delta.", "Minha fala completa."])
    XCTAssertEqual(recovered.context.turns.first?.interrupted, true)
    XCTAssertEqual(recovered.context.turns.last?.interrupted, true)
    XCTAssertTrue(recovered.context.turns.first?.id.hasSuffix(":item-output") == true)
    XCTAssertTrue(recovered.context.turns.last?.id.hasSuffix(":item-user") == true)
    XCTAssertEqual(recovered.pending.count, 3)
    if case .some(.end) = recovered.pending.last {} else { XCTFail("End must follow both durable turns") }
    XCTAssertEqual(controller.state.phase, .idle)
  }

  func testCallOfferUsesMemoryAsInitialItemsWithoutExtendingInstructions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/voice-controller-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4180")!)
    let client = OpenCodeClient(configuration: configuration, transport: { request in
      let body: String
      switch request.url?.lastPathComponent {
      case "info": body = #"{"output":{"version":2,"storage":"kv","contextFormat":"initial_items","scopes":["global"]}}"#
      case "context": body = #"{"output":{"version":2,"scope":"global","summary":"A palavra sintética é pitanga violeta.","turns":[],"approxTokens":30,"updatedAt":0,"truncated":false}}"#
      default: body = #"{"output":{}}"#
      }
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let memory = VoiceMemoryStore(client: client, root: root)
    let transport = VoiceTestTransport()
    let http = VoiceTestHTTP()
    let answered = expectation(description: "answered with memory")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }, memory: memory))
    controller.start(sessions: SessionStore(configuration: configuration))
    await fulfillment(of: [answered], timeout: 3)
    let requests = await http.requests
    let offer = try XCTUnwrap(requests.first { $0.url?.path.hasSuffix("/calls") == true })
    let session = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(offer.httpBody)).object?["session"]?.object
    XCTAssertEqual(session?["instructions"]?.string, VoiceProtocol.instructions)
    XCTAssertTrue(session?["initial_items"]?.array?.first?.object?["content"]?.array?.first?.object?["text"]?.string?.contains("pitanga violeta") == true)
    await controller.end()
    await memory.stop()
  }

  func testExplicitSilentLiveMemorySignaling() async throws {
    #if targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard environment["OPENCODE_TEST_LIVE_VOICE"] == "1",
      environment["OPENCODE_TEST_SERVER_URL"] == "http://127.0.0.1:4180" else {
      throw XCTSkip("Explicit one-call simulator probe only; never enabled by the normal suite.")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/voice-live-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4180")!, password: environment["OPENCODE_TEST_PASSWORD"])
    let memory = VoiceMemoryStore(client: OpenCodeClient(configuration: configuration), root: root)
    let prepared = await memory.prepare()
    guard let seed = prepared, !seed.initialItems.isEmpty else {
      await memory.stop()
      XCTFail("The owned sandbox must supply initial history before spending a live call")
      return
    }
    let http = LiveMemoryHTTP()
    let ready = expectation(description: "native connection and session.started")
    let readiness = LiveReadiness(ready)
    let controller = VoiceController(testing: .init(transport: { callback in
      SilentLiveTransport { event in
        callback(event)
        readiness.receive(event)
      }
    }, master: { _ in VoiceTestMaster() }, request: { try await http.perform($0) }, memory: memory))
    controller.start(sessions: SessionStore(configuration: configuration))
    await fulfillment(of: [ready], timeout: 20)
    await controller.end()
    await memory.stop()
    let metrics = await http.metrics
    let evidence = XCTAttachment(data: try JSONEncoder().encode(metrics), uniformTypeIdentifier: "public.json")
    evidence.name = "memory-live-probe"; evidence.lifetime = .keepAlways; add(evidence)
    XCTAssertEqual(metrics.creates, 1)
    XCTAssertEqual(metrics.statuses, [201])
    XCTAssertEqual(metrics.releases, [204])
    XCTAssertTrue(metrics.initialItems > 0 && metrics.initialItems <= 128)
    XCTAssertLessThanOrEqual(metrics.initialTokens, 8192)
    XCTAssertEqual(metrics.roles, ["assistant", "user"])
    #else
    throw XCTSkip("No physical device live probing in this suite.")
    #endif
  }
}
