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
  var connects = true
  func offer() async throws -> String { "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" }
  func answer(_ sdp: String) async throws {
    guard connects else { answered?(); return }
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
  let rejectedVoices: [String]
  init(rejectedVoices: [String] = []) { self.rejectedVoices = rejectedVoices }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    if request.url!.path.hasSuffix("/calls") {
      let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
      if rejectedVoices.contains(body.object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"]?.string ?? "") {
        return (Data(#"{"error":{"type":"invalid_request_error","param":"session.audio.output.voice","code":"unsupported_value"}}"#.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
      }
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

@MainActor private final class VoiceTestPath: VoicePathMonitoring {
  var current = VoicePath(satisfied: true, interfaces: ["wifi:en0"])
  var change: (@MainActor (VoicePath) -> Void)?
  func start(_ change: @escaping @MainActor (VoicePath) -> Void) { self.change = change }
  func stop() { change = nil }
  func set(_ path: VoicePath) { current = path; change?(path) }
}

@MainActor private final class VoiceTestCues: VoiceCueing {
  var played: [VoiceCue] = []
  var stops = 0
  func play(_ cue: VoiceCue) { played.append(cue) }
  func stop() { stops += 1 }
}

/// Every link gets a fresh transport so recovery can be observed call by call.
@MainActor private final class VoiceTransportPool {
  var transports: [VoiceTestTransport] = []
  var connects = true
  func make(_ event: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) -> any VoiceTransporting {
    let transport = VoiceTestTransport()
    transport.event = event; transport.connects = connects
    transports.append(transport)
    return transport
  }
}

/// Proxy double whose renewals and reservations can fail like an unreachable WARP route.
private actor VoiceFlakyHTTP {
  var requests: [URLRequest] = []
  let lease: TimeInterval
  var renewalErrors: Int
  let renewalStatus: Int?
  let reservations: Int
  init(lease: TimeInterval = 60, renewalErrors: Int = 0, renewalStatus: Int? = nil, reservations: Int = .max) {
    self.lease = lease; self.renewalErrors = renewalErrors; self.renewalStatus = renewalStatus; self.reservations = reservations
  }
  func count(_ method: String, calls: Bool = false) -> Int {
    requests.filter { $0.httpMethod == method && ($0.url?.path.hasSuffix("/calls") == true) == calls }.count
  }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    let url = request.url!
    if request.httpMethod == "DELETE" { return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!) }
    if url.path.hasSuffix("/calls") {
      return (Data("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n".utf8),
        HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Location": "/v1/live/test"])!)
    }
    if request.httpMethod == "PUT" {
      if renewalErrors > 0 { renewalErrors -= 1; throw URLError(.timedOut) }
      if let renewalStatus {
        return (Data(), HTTPURLResponse(url: url, statusCode: renewalStatus, httpVersion: nil, headerFields: nil)!)
      }
    }
    if request.httpMethod == "POST", count("POST") > reservations { throw URLError(.cannotConnectToHost) }
    let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (try JSONEncoder().encode(["sessionId": url.lastPathComponent,
      "generation": body["generation"]!, "serverTime": formatter.string(from: .now),
      "leaseExpiresAt": formatter.string(from: .now.addingTimeInterval(lease))]),
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

/// Real WebRTC transport, muted before any offer leaves, that also lets a test inject a media loss.
@MainActor private final class InjectableLiveTransport: VoiceTransporting {
  let event: @MainActor @Sendable (VoiceTransportEvent) -> Void
  private let transport: SilentLiveTransport
  init(event: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) {
    self.event = event; transport = SilentLiveTransport(event: event)
  }
  func offer() async throws -> String { try await transport.offer() }
  func answer(_ sdp: String) async throws { try await transport.answer(sdp) }
  func send(_ data: Data) async throws { try await transport.send(data) }
  func mute(_ muted: Bool) { transport.mute(true) }
  func resume() { transport.resume() }
  func close() async { await transport.close() }
}

/// Real proxy, except renewals can be cut as if the WARP route dropped.
private actor LiveFlakyHTTP {
  var blockRenewals = false
  var renewalFailures = 0
  var creates: [Int] = []
  var releases: [Int] = []
  func block(_ value: Bool) { blockRenewals = value }
  func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    if request.httpMethod == "PUT" && blockRenewals { renewalFailures += 1; throw URLError(.notConnectedToInternet) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if request.url?.path.hasSuffix("/calls") == true { creates.append(status) }
    if request.httpMethod == "DELETE" { releases.append(status) }
    return (data, response)
  }
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
  func testSavedVoiceIsCapturedAtStartAndChangesOnlyTheNextCall() async throws {
    let name = "voice-controller-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = VoicePreferences(defaults: defaults)
    preferences.voice = .viola
    let transport = VoiceTestTransport()
    let http = VoiceTestHTTP()
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }), preferences: preferences)
    let sessions = SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!))
    let first = expectation(description: "first call")
    transport.answered = { first.fulfill() }
    controller.start(sessions: sessions)
    preferences.voice = .cove
    await fulfillment(of: [first], timeout: 3)
    XCTAssertEqual(controller.state.phase, .listening)
    await controller.end()
    let second = expectation(description: "next call")
    transport.answered = { second.fulfill() }
    controller.start(sessions: sessions)
    await fulfillment(of: [second], timeout: 3)
    await controller.end()
    let offers = await http.requests.filter { $0.url?.path.hasSuffix("/calls") == true }
    let voices = try offers.map {
      try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap($0.httpBody)).object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"]?.string
    }
    XCTAssertEqual(voices, ["viola", "cove"])
    XCTAssertNil(controller.toast.message)
  }
  func testFallbackToastDoesNotOverwriteTheSavedPreference() async throws {
    let name = "voice-controller-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = VoicePreferences(defaults: defaults)
    preferences.voice = .maple
    let transport = VoiceTestTransport()
    let http = VoiceTestHTTP(rejectedVoices: ["maple", "rio"])
    let answered = expectation(description: "fallback call")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }), preferences: preferences)
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    XCTAssertEqual(controller.state.phase, .listening)
    XCTAssertEqual(controller.toast.message?.text, "A voz Maple não está disponível; usando Cove")
    XCTAssertEqual(VoicePreferences(defaults: defaults).voice, .maple)
    await controller.end()
  }
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

  // MARK: Network recovery

  private func recoveringController(http: VoiceFlakyHTTP, pool: VoiceTransportPool, path: VoiceTestPath, cues: VoiceTestCues,
    policy: VoiceRecoveryPolicy, memory: VoiceMemoryStore? = nil) -> VoiceController {
    VoiceController(testing: .init(transport: { pool.make($0) }, master: { _ in VoiceTestMaster() },
      request: { try await http.respond($0) }, memory: memory, policy: policy, network: path, cues: cues))
  }
  private func until(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  func testSingleRenewalFailureKeepsTheCall() async throws {
    let http = VoiceFlakyHTTP(renewalErrors: 1)
    let pool = VoiceTransportPool(), path = VoiceTestPath(), cues = VoiceTestCues()
    let controller = recoveringController(http: http, pool: pool, path: path, cues: cues,
      policy: .init(renewal: 0.05, renewalRetry: 0.05))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    let renewed = await until { await http.count("PUT") >= 3 }
    XCTAssertTrue(renewed)
    XCTAssertEqual(controller.state.phase, .listening)
    XCTAssertEqual(pool.transports.count, 1)
    XCTAssertFalse(pool.transports[0].closed)
    XCTAssertEqual(cues.played, [])
    await controller.end()
  }

  func testRenewalFailuresStopAudioAtLeaseExpiryAndExhaustedRecoveryOffersRetry() async throws {
    // Lease minus the fixed ten-second margin leaves 0.6 s; the proxy then stays unreachable.
    let http = VoiceFlakyHTTP(lease: 10.6, renewalErrors: .max, reservations: 1)
    let pool = VoiceTransportPool(), path = VoiceTestPath(), cues = VoiceTestCues()
    let controller = recoveringController(http: http, pool: pool, path: path, cues: cues,
      policy: .init(renewal: 0.05, renewalRetry: 0.05, window: 1, backoff: [0.05, 0.05], attemptTimeout: 0.3))
    let sessions = SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!))
    controller.start(sessions: sessions)
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    let failedRenewal = await until { await http.count("PUT") >= 1 }
    XCTAssertTrue(failedRenewal)
    XCTAssertFalse(pool.transports[0].closed, "a transient renewal failure inside the lease keeps audio")
    let stopped = await until { pool.transports[0].closed }
    XCTAssertTrue(stopped, "audio stops when the confirmed lease minus its margin ends")
    XCTAssertEqual(cues.played.first, .lost)
    let failed = await until(4) { controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertEqual(cues.played, [.lost, .failed])
    XCTAssertTrue(controller.alert?.contains("Não consegui reconectar") == true)
    let calls = await http.count("POST", calls: true)
    XCTAssertEqual(calls, 1, "an unreachable reservation never creates another call")
    await controller.retry(sessions: sessions)
    XCTAssertNil(controller.alert)
    await controller.end()
  }

  func testRefusedRenewalStillEndsTheCallAtOnce() async throws {
    let http = VoiceFlakyHTTP(renewalStatus: 403)
    let pool = VoiceTransportPool(), path = VoiceTestPath(), cues = VoiceTestCues()
    let controller = recoveringController(http: http, pool: pool, path: path, cues: cues, policy: .init(renewal: 0.05))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let failed = await until { controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertEqual(controller.detail, "A autorização da voz não pôde ser renovada. A chamada foi encerrada por segurança.")
    XCTAssertTrue(pool.transports[0].closed)
    XCTAssertEqual(cues.played, [])
    XCTAssertNil(controller.alert)
    let reservations = await http.count("POST")
    XCTAssertEqual(reservations, 1)
    await controller.end()
  }

  func testNetworkLossRebuildsTheCallWithMemoryWhenTheNetworkReturns() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/voice-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4180")!)
    let client = OpenCodeClient(configuration: configuration, transport: { request in
      let body: String
      switch request.url?.lastPathComponent {
      case "info": body = #"{"output":{"version":2,"storage":"kv","contextFormat":"initial_items","scopes":["global"]}}"#
      case "context": body = #"{"output":{"version":2,"scope":"global","summary":"","turns":[],"approxTokens":0,"updatedAt":0,"truncated":false}}"#
      // Appends stay pending, as they would while the Mac is unreachable.
      default: return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
      }
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    let memory = VoiceMemoryStore(client: client, root: root)
    let http = VoiceFlakyHTTP()
    let pool = VoiceTransportPool(), path = VoiceTestPath(), cues = VoiceTestCues()
    let controller = recoveringController(http: http, pool: pool, path: path, cues: cues,
      policy: .init(renewal: 5, mediaGrace: 5, backoff: [0.05]), memory: memory)
    controller.start(sessions: SessionStore(configuration: configuration))
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    let call = controller.sessionID
    controller.mute()
    pool.transports[0].event?(.data(Data(#"{"type":"turn.done","turn":{"id":"before-tunnel","role":"user","transcript":"Lembre a palavra jabuticaba."}}"#.utf8)))
    path.set(VoicePath(satisfied: false))
    pool.transports[0].event?(.disconnected)
    XCTAssertEqual(controller.state.phase, .offline)
    XCTAssertEqual(VoiceIndicator(controller.state), .offline)
    path.set(VoicePath(satisfied: true, interfaces: ["cellular:pdp_ip0"]))
    let rebuilt = await until { pool.transports.count == 2 && controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    XCTAssertTrue(pool.transports[0].closed)
    XCTAssertTrue(pool.transports[1].muted, "mute survives the rebuilt call")
    XCTAssertEqual(cues.played, [.lost, .restored])
    XCTAssertEqual(controller.sessionID, call)
    XCTAssertNil(controller.alert)
    let requests = await http.requests
    let offers = requests.filter { $0.url?.path.hasSuffix("/calls") == true }
    XCTAssertEqual(offers.count, 2)
    let reservations = requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/calls") == false }
    XCTAssertEqual(Set(reservations.map(\.url)).count, 2, "each rebuilt call has its own lease")
    let released = await until { await http.count("DELETE") >= 1 }
    XCTAssertTrue(released)
    let session = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(offers[1].httpBody)).object?["session"]?.object
    let texts = session?["initial_items"]?.array?.flatMap { $0.object?["content"]?.array ?? [] }.compactMap { $0.object?["text"]?.string } ?? []
    XCTAssertTrue(texts.contains("Lembre a palavra jabuticaba."))
    await controller.end()
    await memory.stop()
  }

  func testMediaFailureWithoutNetworkWaitsThenGivesUpWithAlert() async throws {
    let http = VoiceFlakyHTTP()
    let pool = VoiceTransportPool(), path = VoiceTestPath(), cues = VoiceTestCues()
    let controller = recoveringController(http: http, pool: pool, path: path, cues: cues,
      policy: .init(window: 0.4, backoff: [0.05], networkPoll: 0.02))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    path.set(VoicePath(satisfied: false))
    pool.transports[0].event?(.failed)
    XCTAssertEqual(controller.state.phase, .offline)
    let failed = await until { controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertEqual(pool.transports.count, 1, "no attempt is made without a network path")
    XCTAssertEqual(cues.played, [.lost, .failed])
    XCTAssertNotNil(controller.alert)
    controller.dismissAlert()
    XCTAssertNil(controller.alert)
    await controller.end()
  }

  func testFailureBeforeTheFirstConnectionIsNotRetried() async throws {
    let http = VoiceFlakyHTTP()
    let pool = VoiceTransportPool(), path = VoiceTestPath(), cues = VoiceTestCues()
    pool.connects = false
    let controller = recoveringController(http: http, pool: pool, path: path, cues: cues, policy: .init())
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let offered = await until { await http.count("POST", calls: true) == 1 }
    XCTAssertTrue(offered)
    pool.transports[0].event?(.failed)
    let failed = await until { controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertEqual(pool.transports.count, 1)
    XCTAssertEqual(cues.played, [])
    XCTAssertNil(controller.alert)
    await controller.end()
  }

  func testExplicitSilentLiveRecovery() async throws {
    #if targetEnvironment(simulator)
    guard ProcessInfo.processInfo.environment["OPENCODE_TEST_LIVE_VOICE_RECOVERY"] == "1" else {
      throw XCTSkip("Explicit two-call muted simulator recovery probe only; never enabled by the normal suite.")
    }
    let http = LiveFlakyHTTP()
    let path = VoiceTestPath()
    var transports: [InjectableLiveTransport] = []
    let controller = VoiceController(testing: .init(transport: { event in
      let transport = InjectableLiveTransport(event: event)
      transports.append(transport)
      return transport
    }, master: { _ in VoiceTestMaster() }, request: { try await http.perform($0) }, network: path, cues: VoiceCuePlayer()))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let ready = await until(25) { controller.state.phase == .listening }
    XCTAssertTrue(ready, controller.detail)
    guard ready else { await controller.end(); return }
    // One renewal (every five seconds) fails while the 60 s lease is valid: the call must stay.
    await http.block(true)
    let missed = await until(8) { await http.renewalFailures >= 1 }
    await http.block(false)
    XCTAssertTrue(missed)
    try await Task.sleep(for: .seconds(6))
    XCTAssertEqual(controller.state.phase, .listening)
    XCTAssertEqual(transports.count, 1)
    // A media loss rebuilds a second real call.
    transports[0].event(.failed)
    XCTAssertEqual(controller.state.phase, .reconnecting)
    let recovered = await until(30) { transports.count == 2 && controller.state.phase == .listening }
    XCTAssertTrue(recovered, controller.detail)
    await controller.end()
    let released = await until(10) { await http.releases.count >= 2 }
    XCTAssertTrue(released)
    let creates = await http.creates, releases = await http.releases, failures = await http.renewalFailures
    let evidence = XCTAttachment(data: try JSONEncoder().encode(["creates": creates, "releases": releases, "renewalFailures": [failures]]),
      uniformTypeIdentifier: "public.json")
    evidence.name = "voice-recovery-live"; evidence.lifetime = .keepAlways; add(evidence)
    XCTAssertEqual(creates, [201, 201])
    XCTAssertEqual(releases, [204, 204])
    #else
    throw XCTSkip("No physical device live probing in this suite.")
    #endif
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

  func testExplicitSilentVoiceCatalogSample() async throws {
    #if targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard environment["OPENCODE_TEST_LIVE_VOICE_CATALOG"] == "1",
      environment["OPENCODE_TEST_SERVER_URL"] == "http://127.0.0.1:4177" else {
      throw XCTSkip("Explicit six-call muted simulator catalog probe only.")
    }
    var results: [JSONValue] = []
    for id in ["porto", "selva", "tinta", "sol", "maple", "juniper"] {
      let voice = try XCTUnwrap(GPTLiveVoice(rawValue: id))
      let transport = SilentLiveTransport(event: { _ in })
      let signal = VoiceSignaling()
      do {
        let sdp = try await transport.offer()
        let (lease, reservation) = try await URLSession.shared.data(for: signal.leaseRequest(method: "POST"))
        _ = try signal.parseLease(lease, status: (reservation as? HTTPURLResponse)?.statusCode ?? 0)
        let (data, result) = try await URLSession.shared.data(for: signal.offerRequest(sdp: sdp, voice: voice))
        let response = try XCTUnwrap(result as? HTTPURLResponse)
        let accepted = response.statusCode == 201
        if accepted { _ = try VoiceSignaling.parseAnswer(data, response: response) }
        let rejected = VoiceSignaling.rejectsVoice(data, response: response)
        await transport.close()
        let (_, release) = try await URLSession.shared.data(for: signal.leaseRequest(method: "DELETE"))
        let released = (release as? HTTPURLResponse)?.statusCode ?? 0
        results.append(.object(["voice": .string(id), "status": .number(Double(response.statusCode)),
          "accepted": .bool(accepted), "voiceValidationRejected": .bool(rejected), "release": .number(Double(released))]))
        let evidence = XCTAttachment(data: try JSONEncoder().encode(results), uniformTypeIdentifier: "public.json")
        evidence.name = "voice-catalog-live"; evidence.lifetime = .keepAlways; add(evidence)
        XCTAssertEqual(released, 204)
        guard accepted || rejected else { XCTFail("Non-validation failure; stop without spending more calls"); return }
      } catch {
        await transport.close()
        _ = try? await URLSession.shared.data(for: signal.leaseRequest(method: "DELETE"))
        throw error
      }
    }
    XCTAssertEqual(results.count, 6)
    #else
    throw XCTSkip("No physical device live probing in this suite.")
    #endif
  }
}
