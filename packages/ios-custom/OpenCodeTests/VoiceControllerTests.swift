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
  /// The data channel refuses to send, as when it stalls during a network loss.
  var sendFails = false
  /// The service answers `session.close` with `session.closed`, as on 02/11; off, ending waits for something else.
  var answersClose = true
  /// The service confirms each append (`*.context.appended`, within 0.25 s on 02/11, here at once); off, none.
  var confirms = true
  /// The call ID `session.started` names (`session.id`); nil names none.
  var startedCall: String?
  func offer() async throws -> String { "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" }
  func answer(_ sdp: String) async throws {
    guard connects else { answered?(); return }
    var started: [String: JSONValue] = ["type": .string("session.started")]
    if let startedCall {
      started["session"] = .object(["id": .string(startedCall), "status": .string("active"), "expires_at": .number(1_793_647_619)])
    }
    event?(.connected); event?(.data(try JSONEncoder().encode(JSONValue.object(started)))); answered?()
  }
  func send(_ data: Data) async throws {
    if sendFails { throw VoiceWireError.invalidEvent }
    frames.append(data)
    let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object
    switch object?["type"]?.string {
    case "session.close" where answersClose:
      event?(.data(Data(#"{"type":"session.closed","reason":"client_request","usage":{"audio_duration_ms":4200,"backend_model_usage":[]}}"#.utf8)))
    case "session.context.append" where confirms:
      event?(.data(Data(#"{"type":"session.context.appended","start_ms":12200,"end_ms":12400}"#.utf8)))
    case "delegation.context.append" where confirms:
      event?(.data(try JSONEncoder().encode(JSONValue.object(["type": .string("delegation.context.appended"),
        "delegation_item_id": object?["delegation_item_id"] ?? .null, "start_ms": .number(30600), "end_ms": .number(30800)]))))
    default: break
    }
  }
  /// The type of every frame sent on this call, in order.
  var types: [String] { frames.compactMap(VoiceProtocol.eventType) }
  /// The `event_id` of the last frame of one type sent on this call.
  func eventID(_ type: String) -> String? {
    frames.compactMap { (try? JSONDecoder().decode(JSONValue.self, from: $0))?.object }
      .last { $0["type"]?.string == type }?["event_id"]?.string
  }
  /// The text of every frame of one type sent on this call, joined: by default what GPT Live says (a frame without a
  /// channel is spoken), `.commentary` for its quiet state.
  func sent(_ type: String, item: String? = nil, channel: VoiceChannel = .speakable) -> String {
    frames.compactMap { frame -> String? in
      let object = (try? JSONDecoder().decode(JSONValue.self, from: frame))?.object
      guard object?["type"]?.string == type, item == nil || object?["delegation_item_id"]?.string == item,
        (object?["channel"]?.string ?? VoiceChannel.speakable.rawValue) == channel.rawValue else { return nil }
      return object?["content"]?.array?.first?.object?["text"]?.string
    }.joined()
  }
  func mute(_ muted: Bool) { self.muted = muted }
  func resume() { event?(.resumed) }
  func close() async { closed = true }
}

@MainActor private final class VoiceTestMaster: VoiceMasterServing {
  var requests: [VoiceMasterRequest] = []
  var update: ((VoiceMasterUpdate) -> Void)?
  var asked: (() -> Void)?
  var stopped = false
  var screens: [VoiceScreenShot?] = []
  func ask(_ request: VoiceMasterRequest, screen: VoiceScreenShot?) async throws {
    requests.append(request); screens.append(screen)
    update?(.activity("Consultando a sessão de teste.", note: VoiceMasterProgress.note("consultando a sessão de teste")))
    asked?()
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

private actor VoiceTestInstructions {
  private var calls = 0
  func load() -> String { calls += 1; return "Prompt do servidor \(calls)" }
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
  var answersClose = true
  var confirms = true
  func make(_ event: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) -> any VoiceTransporting {
    let transport = VoiceTestTransport()
    transport.event = event; transport.connects = connects; transport.answersClose = answersClose
    transport.confirms = confirms
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
  /// Renewals answered 500 before they go through again, like the proxy losing its Redis for a moment.
  var renewalOutages: Int
  init(lease: TimeInterval = 60, renewalErrors: Int = 0, renewalStatus: Int? = nil, reservations: Int = .max,
    renewalOutages: Int = 0) {
    self.lease = lease; self.renewalErrors = renewalErrors; self.renewalStatus = renewalStatus; self.reservations = reservations
    self.renewalOutages = renewalOutages
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
      if renewalOutages > 0 {
        renewalOutages -= 1
        return (Data(#"{"error":"gpt_live_lease_unavailable"}"#.utf8), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
      }
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

/// Raw data-channel events of a probe, truncated, with no audio.
@MainActor private final class LiveEventRecorder {
  var events: [String] = []
  var ready = false
  func receive(_ event: VoiceTransportEvent) {
    guard case .data(let data) = event else { return }
    let text = String(decoding: data.prefix(600), as: UTF8.self)
    events.append(text)
    if text.contains("\"session.started\"") { ready = true }
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
    if case .data(let data) = event, case .ready = try? VoiceProtocol.decode(data) { protocolReady = true }
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
    let instructions = VoiceTestInstructions()
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) },
      instructions: { await instructions.load() }), preferences: preferences)
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
    let prompts = try offers.map {
      try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap($0.httpBody)).object?["session"]?.object?["instructions"]?.string
    }
    // The edited server prompt is used as is; the app adds only its fixed screen capability.
    XCTAssertEqual(prompts, ["Prompt do servidor 1", "Prompt do servidor 2"].map { VoiceProtocol.withScreen($0, for: .iPhone) })
    XCTAssertNil(controller.toast.message)
  }
  func testUnavailableServerPromptDoesNotReachProxy() async {
    let http = VoiceTestHTTP()
    let controller = VoiceController(testing: .init(transport: { _ in VoiceTestTransport() },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) },
      instructions: { throw ClientError.operation("Não foi possível carregar o prompt de voz.") }))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await controller.settled(within: .seconds(3))
    XCTAssertEqual(controller.state.phase, .failed)
    let requests = await http.requests
    XCTAssertTrue(requests.isEmpty)
    await controller.end()
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
    XCTAssertEqual(session?["instructions"]?.string, VoiceProtocol.withScreen("Instruções da fixture de voz.", for: .iPhone))
    XCTAssertTrue(session?["initial_items"]?.array?.first?.object?["content"]?.array?.first?.object?["text"]?.string?.contains("pitanga violeta") == true)
    await controller.end()
    await memory.stop()
  }

  // MARK: Screen for the master

  /// A report names the category, GPT Live's error code and the last events, never what was said. A GPT Live error
  /// is tolerated: the call goes on and the report says so.
  func testFailureReportCarriesTheCategoryCodeAndEventNamesOnly() async throws {
    let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { update in master.update = update; return master }, request: { try await http.respond($0) },
      diagnostics: outbox))
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    transport.event?(.data(Data(#"{"type":"output_transcript.added","item":{"id":"o1","text":"Frase falada jabuticaba"}}"#.utf8)))
    transport.event?(.data(Data(#"{"type":"error","error":{"type":"invalid_request_error","code":"unknown_event","message":"Mensagem do provedor"}}"#.utf8)))
    let reported = await until { await outbox.pending().count == 1 }
    XCTAssertTrue(reported)
    XCTAssertEqual(controller.state.phase, .speaking, "the call goes on")
    let pending = await outbox.pending()
    let report = try XCTUnwrap(pending.first)
    XCTAssertEqual(report.kind, .tolerated)
    XCTAssertEqual(report.reason, "service_error")
    XCTAssertEqual(report.code, "invalid_request_error/unknown_event")
    XCTAssertEqual(report.platform, "ios")
    XCTAssertEqual(Array(report.events.suffix(2)), ["output_transcript.added", "error"])
    let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    // Speech never; the provider's error message only as the sanitized `detail` (since f67b3a9c4b).
    XCTAssertFalse(json.contains("jabuticaba"))
    XCTAssertEqual(report.detail, "Mensagem do provedor")
    await controller.end()
    let ended = await until { await outbox.pending().last?.reason == "user_end" }
    XCTAssertTrue(ended)
    XCTAssertTrue(transport.closed)
  }

  private func screenController(_ transport: VoiceTestTransport, _ master: VoiceTestMaster, _ http: VoiceTestHTTP,
    locked: Bool = false,
    screen: @escaping @MainActor (VoiceScreenTarget, String?) async throws(VoiceScreenRefusal) -> VoiceScreenShot) -> VoiceController {
    VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { update in master.update = update; return master }, request: { try await http.respond($0) }, screen: screen,
      screenLocked: locked))
  }

  /// A locked iPhone never tries a capture: asked for the screen, GPT Live hears to unlock first and nothing goes;
  /// a guess from his words is dropped and the request goes as delegated.
  func testLockedIPhoneNeverCapturesTheScreen() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    var captures = 0
    let controller = screenController(transport, master, http, locked: true) { _, id throws(VoiceScreenRefusal) in
      captures += 1; return VoiceScreenShot(jpeg: Data([0xFF, 0xD8, 1]), sessionID: id)
    }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"l1","content":[{"type":"input_text","text":"{\"text\":\"Dá uma olhada nessa tela\",\"screen\":true}"}]}}"#.utf8)))
    let refused = await until { controller.detail == VoiceScreenRefusal.locked.localizedDescription }
    XCTAssertTrue(refused)
    let asked = expectation(description: "asked")
    master.asked = { asked.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"l2","content":[{"type":"input_text","text":"Tá vendo minha tela?"}]}}"#.utf8)))
    await fulfillment(of: [asked], timeout: 3)
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(master.requests.map(\.text), ["Tá vendo minha tela?"])
    XCTAssertEqual(master.requests.map(\.screen), [nil])
    await controller.end()
  }

  /// 31/10: "vê o que cê acha" closed a request to search the web; it is not about the screen.
  func testPointingWordsWithoutTheScreenDoNotCapture() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    var captures = 0
    let controller = screenController(transport, master, http) { _, id throws(VoiceScreenRefusal) in
      captures += 1; return VoiceScreenShot(jpeg: Data([0xFF, 0xD8, 2]), sessionID: id)
    }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    let asked = expectation(description: "asked")
    master.asked = { asked.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"v1","content":[{"type":"input_text","text":"Dá uma pesquisada na web, vê o que cê acha desse relato"}]}}"#.utf8)))
    await fulfillment(of: [asked], timeout: 3)
    XCTAssertEqual(captures, 0)
    XCTAssertEqual(master.requests.map(\.screen), [nil])
    await controller.end()
  }

  func testScreenDelegationAttachesTheCaptureTakenWhenGPTLiveDelegated() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    var captured: [String?] = []
    let controller = screenController(transport, master, http) { _, id throws(VoiceScreenRefusal) in
      captured.append(id); return VoiceScreenShot(jpeg: Data([0xFF, 0xD8, 9]), sessionID: id)
    }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    let asked = expectation(description: "asked")
    master.asked = { asked.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"s1","content":[{"type":"input_text","text":"{\"text\":\"Dá uma olhada nessa tela\",\"screen\":true}"}]}}"#.utf8)))
    XCTAssertEqual(captured.count, 1, "the capture starts synchronously with the delegation")
    await fulfillment(of: [asked], timeout: 3)
    XCTAssertEqual(master.requests.map(\.text), ["Dá uma olhada nessa tela"])
    XCTAssertEqual(master.screens.first??.jpeg, Data([0xFF, 0xD8, 9]))
    // A normal delegation still goes without any capture.
    let plain = expectation(description: "plain")
    master.asked = { plain.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"s2","content":[{"type":"input_text","text":"Só texto"}]}}"#.utf8)))
    await fulfillment(of: [plain], timeout: 3)
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(master.screens.count, 2)
    XCTAssertNil(master.screens.last!)
    await controller.end()
  }

  /// The two phrases of 29/10: GPT Live delegated without `"screen"`. The app still sends the capture.
  func testScreenQuestionsDelegatedAsPlainTextStillCarryTheCapture() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    var targets: [VoiceScreenTarget] = []
    let controller = screenController(transport, master, http) { target, id throws(VoiceScreenRefusal) in
      targets.append(target); return VoiceScreenShot(jpeg: Data([0xFF, 0xD8, 5]), sessionID: id)
    }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    func say(_ text: String) {
      let piece = try! JSONEncoder().encode(JSONValue.object(["type": .string("input_transcript.added"),
        "item": .object(["id": .string(UUID().uuidString), "text": .string(text)])]))
      transport.event?(.data(piece))
    }
    func delegate(_ id: String, _ text: String) async {
      let asked = expectation(description: id)
      master.asked = { asked.fulfill() }
      let event = try! JSONEncoder().encode(JSONValue.object(["type": .string("delegation.created"), "item": .object([
        "type": .string("delegation"), "target": .string("client"), "id": .string(id),
        "content": .array([.object(["type": .string("input_text"), "text": .string(text)])])])]))
      transport.event?(.data(event))
      await fulfillment(of: [asked], timeout: 3)
    }
    // A question about the screen, delegated as it was said.
    say(" Você está vendo a minha tela aí?")
    await delegate("q1", "Você está vendo a minha tela aí?")
    // A question GPT Live answered itself, then a follow-up that does not name the screen.
    say(" Você está vendo a minha tela aí?")
    say(" Não, vai lá na Mestra que você consegue")
    await delegate("q2", "Não, vai lá na Mestra que você consegue")
    // Unrelated: no capture.
    say(" Cria uma sessão no abacato")
    await delegate("q3", "Cria uma sessão no abacato")
    // "A tela toda" asks for the whole screen (the Mac's; the iPhone captures its own window anyway).
    say(" Olha minha tela toda")
    await delegate("q4", "Olha minha tela toda")
    XCTAssertEqual(targets, [.front, .front, .display])
    XCTAssertEqual(master.requests.map(\.screen), [.front, .front, nil, .display])
    XCTAssertEqual(master.requests.map(\.text), ["Você está vendo a minha tela aí?",
      "Não, vai lá na Mestra que você consegue", "Cria uma sessão no abacato", "Olha minha tela toda"])
    XCTAssertEqual(master.screens.map { $0 != nil }, [true, true, false, true])
    await controller.end()
  }

  func testInferredCaptureThatFailsStillSendsTheTextAsDelegated() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    let controller = screenController(transport, master, http) { _, _ throws(VoiceScreenRefusal) in throw .background }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    let asked = expectation(description: "asked")
    master.asked = { asked.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"q4","content":[{"type":"input_text","text":"Tá conseguindo ver minha tela"}]}}"#.utf8)))
    await fulfillment(of: [asked], timeout: 3)
    // The capture was only a guess, which can be wrong: its failure adds no note about the screen.
    XCTAssertEqual(master.requests.first?.text, "Tá conseguindo ver minha tela")
    XCTAssertNil(master.requests.first?.screen)
    XCTAssertNil(master.screens.first!)
    await controller.end()
  }

  func testRefusedScreenReachesOnlyGPTLiveWithAClearReason() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    let controller = screenController(transport, master, http) { _, _ throws(VoiceScreenRefusal) in throw .background }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"s3","content":[{"type":"input_text","text":"{\"text\":\"O que é isso aqui?\",\"screen\":true}"}]}}"#.utf8)))
    let deadline = Date.now.addingTimeInterval(3)
    while transport.frames.isEmpty, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(master.requests.isEmpty, "nothing reaches the master")
    let frame = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(transport.frames.first)).object
    XCTAssertEqual(frame?["type"]?.string, "delegation.context.append")
    XCTAssertEqual(frame?["delegation_item_id"]?.string, "s3")
    let spoken = transport.frames.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0).object?["content"]?.array?.first?.object?["text"]?.string }.joined()
    XCTAssertEqual(spoken, VoiceScreenRefusal.background.localizedDescription)
    XCTAssertEqual(controller.toast.message?.text, VoiceScreenRefusal.background.localizedDescription)
    XCTAssertEqual(controller.state.phase, .listening)
    await controller.end()
  }

  func testScreenTargetReachesTheCaptureAndANoticeIsSpokenAfterSending() async throws {
    let transport = VoiceTestTransport(), master = VoiceTestMaster(), http = VoiceTestHTTP()
    var targets: [VoiceScreenTarget] = []
    let controller = screenController(transport, master, http) { target, _ throws(VoiceScreenRefusal) in
      targets.append(target)
      return VoiceScreenShot(jpeg: Data([0xFF, 0xD8, 7]), sessionID: nil, subject: "da janela do OpenCode",
        notice: VoiceScreenPlanner.deniedNotice)
    }
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    let asked = expectation(description: "asked")
    master.asked = { asked.fulfill() }
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"s4","content":[{"type":"input_text","text":"{\"text\":\"Olha o simulador\",\"screen\":\"app\",\"screen_app\":\"Simulator\"}"}]}}"#.utf8)))
    await fulfillment(of: [asked], timeout: 3)
    XCTAssertEqual(targets, [.app("Simulator")])
    XCTAssertEqual(master.screens.first??.notice, VoiceScreenPlanner.deniedNotice)
    let deadline = Date.now.addingTimeInterval(3)
    while transport.sent("delegation.context.append").isEmpty, Date.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(transport.sent("delegation.context.append"), VoiceScreenPlanner.deniedNotice)
    XCTAssertEqual(controller.toast.message?.text, VoiceScreenPlanner.deniedNotice)
    await controller.end()
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
      policy: .init(renewal: 5, mediaGrace: 5, handoverGrace: 0.05, backoff: [0.05]), memory: memory)
    controller.start(sessions: SessionStore(configuration: configuration))
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    let call = controller.sessionID
    controller.mute()
    pool.transports[0].event?(.data(Data(#"{"type":"turn.done","turn":{"id":"before-tunnel","role":"user","transcript":"Lembre a palavra jabuticaba."}}"#.utf8)))
    // Said after it, with its `turn.done` still to come when the call drops.
    for piece in [" E a", " palavra seguinte?"] {
      pool.transports[0].event?(.data(try JSONEncoder().encode(JSONValue.object(["type": .string("input_transcript.added"),
        "item": .object(["id": .string("item-tunnel"), "text": .string(piece)])]))))
    }
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
    XCTAssertTrue(texts.contains("E a palavra seguinte?\n[Fala interrompida; o trecho final pode não ter sido ouvido.]"),
      "what was said before the loss without its turn.done reaches the rebuilt call")
    // The lost session was asked to close, without waiting for it.
    XCTAssertEqual(pool.transports[0].types, ["session.close"])
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
    pool.transports[0].event?(.failed(.iceFailed))
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
    pool.transports[0].event?(.failed(.iceFailed))
    let failed = await until { controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertEqual(pool.transports.count, 1)
    XCTAssertEqual(cues.played, [])
    XCTAssertNil(controller.alert)
    await controller.end()
  }

  // MARK: Resilience (31/10)

  private struct Resilient {
    let controller: VoiceController
    let pool: VoiceTransportPool
    let master: VoiceTestMaster
    let http: VoiceFlakyHTTP
    let path: VoiceTestPath
    let outbox: VoiceDiagnosticsOutbox
    func reports(_ reason: String) async -> [VoiceDiagnostic] { await outbox.pending().filter { $0.reason == reason } }
    func offers() async throws -> [[String: JSONValue]] {
      try await http.requests.filter { $0.url?.path.hasSuffix("/calls") == true }.map {
        try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: XCTUnwrap($0.httpBody)).object?["session"]?.object)
      }
    }
  }
  private func resilient(_ policy: VoiceRecoveryPolicy = .init(backoff: [0.05]), http: VoiceFlakyHTTP = VoiceFlakyHTTP()) async -> Resilient {
    let pool = VoiceTransportPool(), path = VoiceTestPath(), master = VoiceTestMaster()
    let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
    let controller = VoiceController(testing: .init(transport: { pool.make($0) },
      master: { update in master.update = update; return master }, request: { try await http.respond($0) },
      policy: policy, network: path, cues: VoiceTestCues(), diagnostics: outbox))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    _ = await until { controller.state.phase == .listening }
    return Resilient(controller: controller, pool: pool, master: master, http: http, path: path, outbox: outbox)
  }
  private func delegation(_ id: String, _ text: String) -> VoiceTransportEvent {
    .data(try! JSONEncoder().encode(JSONValue.object(["type": .string("delegation.created"), "item": .object([
      "type": .string("delegation"), "target": .string("client"), "id": .string(id),
      "content": .array([.object(["type": .string("input_text"), "text": .string(text)])])])])))
  }

  /// GPT Live errors and events the app cannot read are logged; the call, its transport and the master go on.
  func testServiceErrorsAndUnreadableEventsKeepTheCall() async throws {
    let call = await resilient()
    XCTAssertEqual(call.controller.state.phase, .listening)
    let transport = try XCTUnwrap(call.pool.transports.first)
    for json in [
      #"{"type":"error","error":{"type":"server_error","code":"internal","message":"x"}}"#,
      #"{"type":"error","error":{"type":"invalid_request_error","code":"conversation_already_has_active_response"}}"#,
      #"{"type":"error"}"#,
      "{não é json",
      #"{"sem":"tipo"}"#,
      #"{"type":"turn.done","turn":{}}"#,
      #"{"type":"input_transcript.added","item":{}}"#,
      #"{"type":"delegation.created","item":{"type":"delegation","target":"client"}}"#,
    ] { transport.event?(.data(Data(json.utf8))) }
    // A delegation whose request cannot be read is answered on its own item, so GPT Live asks again.
    transport.event?(.data(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"vazio","content":[]}}"#.utf8)))
    let answered = await until { !transport.sent("delegation.context.append", item: "vazio").isEmpty }
    XCTAssertTrue(answered)
    XCTAssertEqual(transport.sent("delegation.context.append", item: "vazio"), "Não consegui ler esse pedido. Peça para Alexandre repetir.")
    let logged = await until { await call.reports("invalid_event").count == 6 }
    XCTAssertTrue(logged)
    let errors = await call.reports("service_error")
    XCTAssertEqual(errors.map(\.code), ["server_error/internal", "invalid_request_error/conversation_already_has_active_response", nil])
    XCTAssertFalse(call.controller.state.contextCleared, "only moderation clears the context")
    XCTAssertTrue(errors.allSatisfy { $0.kind == .tolerated })
    XCTAssertEqual(call.controller.state.phase, .listening)
    XCTAssertEqual(call.pool.transports.count, 1)
    XCTAssertFalse(transport.closed)
    XCTAssertTrue(call.master.requests.isEmpty)
    // The call still delegates.
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    transport.event?(delegation("depois", "Confira as sessões"))
    await fulfillment(of: [asked], timeout: 3)
    await call.controller.end()
  }

  /// Too many requests waiting for the master: the new one is refused on its own item; nothing ends.
  func testDelegationOverflowRefusesOnlyTheNewRequest() async throws {
    let call = await resilient()
    let transport = try XCTUnwrap(call.pool.transports.first)
    // Delivered together, before the master takes the first one: eight fit in the queue.
    for index in 0..<10 { transport.event?(delegation("q\(index)", "Pedido \(index)")) }
    let refused = await until { !transport.sent("delegation.context.append", item: "q9").isEmpty }
    XCTAssertTrue(refused)
    XCTAssertTrue(transport.sent("delegation.context.append", item: "q8").hasPrefix("Há pedidos demais"))
    let delivered = await until { call.master.requests.count == 8 }
    XCTAssertTrue(delivered)
    XCTAssertEqual(call.master.requests.map(\.text), (0..<8).map { "Pedido \($0)" })
    XCTAssertEqual(call.controller.state.phase, .listening)
    let overflow = await call.reports("delegation_overflow")
    XCTAssertEqual(overflow.map(\.kind), [.tolerated, .tolerated])
    await call.controller.end()
  }

  /// What the master is doing reaches GPT Live as quiet state of the current delegation (`commentary`), never spoken:
  /// not without a delegation, and not while Alexandre speaks.
  func testMasterActivityIsQuietStateOfTheCurrentDelegation() async throws {
    let call = await resilient()
    let transport = try XCTUnwrap(call.pool.transports.first)
    call.master.update?(.activity("A mestra está consultando os arquivos.", note: VoiceMasterProgress.note("consultando os arquivos")))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertTrue(transport.frames.isEmpty, "no delegation to carry it")
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    transport.event?(.data(Data(#"{"type":"input_transcript.added","item":{"id":"u1","text":"e as sessões?"}}"#.utf8)))
    transport.event?(delegation("a", "Confira as sessões"))
    await fulfillment(of: [asked], timeout: 3)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertEqual(transport.sent("delegation.context.append", item: "a", channel: .commentary), "", "he is still speaking")
    let quiet = await until(3) { !transport.sent("delegation.context.append", item: "a", channel: .commentary).isEmpty }
    XCTAssertTrue(quiet)
    XCTAssertEqual(transport.sent("delegation.context.append", item: "a", channel: .commentary),
      VoiceMasterProgress.note("consultando a sessão de teste"))
    XCTAssertEqual(transport.sent("delegation.context.append"), "", "nothing spoken")
    await call.controller.end()
  }

  /// `session_expired` ends GPT Live's session: the call is rebuilt at once instead of failing.
  func testExpiredSessionRebuildsTheCall() async throws {
    let call = await resilient()
    call.pool.transports[0].event?(.data(Data(#"{"type":"error","error":{"type":"invalid_request_error","code":"session_expired"}}"#.utf8)))
    let rebuilt = await until { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    XCTAssertTrue(call.pool.transports[0].closed)
    let lost = await call.reports("service_error")
    XCTAssertEqual(lost.map(\.kind), [.lost])
    XCTAssertEqual(lost.first?.code, "invalid_request_error/session_expired")
    let reconnected = await until { await call.reports("reconnected").first?.code == "attempts_1" }
    XCTAssertTrue(reconnected)
    // session.closed rebuilds too, whatever its reason (expired, unknown or none); the report names it.
    call.pool.transports[1].event?(.data(Data(#"{"type":"session.closed","reason":"expired","usage":{"audio_duration_ms":7200000}}"#.utf8)))
    let again = await until { call.pool.transports.count == 3 && call.controller.state.phase == .listening }
    XCTAssertTrue(again)
    call.pool.transports[2].event?(.data(Data(#"{"type":"session.closed"}"#.utf8)))
    let third = await until { call.pool.transports.count == 4 && call.controller.state.phase == .listening }
    XCTAssertTrue(third)
    let closed = await call.reports("session_closed")
    XCTAssertEqual(closed.map(\.kind), [.lost, .lost])
    XCTAssertEqual(closed.map(\.code), ["expired", nil])
    XCTAssertEqual(closed.first?.detail, "audio_duration_ms=7200000")
    XCTAssertFalse(call.controller.state.contextCleared)
    await call.controller.end()
  }

  /// A failed send rebuilds the call; the result that was not heard reaches the new call once, as call context, and
  /// the master is not asked again.
  func testSendFailureRebuildsAndTheResultReachesTheNewCall() async throws {
    let call = await resilient()
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    call.pool.transports[0].event?(delegation("a", "Pesquise na web o preço do Mac Studio"))
    await fulfillment(of: [asked], timeout: 3)
    call.pool.transports[0].sendFails = true
    call.master.update?(.finished("Custa 10 mil reais."))
    let rebuilt = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    let heard = await until(3) { call.pool.transports[1].sent("session.context.append").contains("Resultado: Custa 10 mil reais.") }
    XCTAssertTrue(heard)
    XCTAssertTrue(call.pool.transports[0].sent("delegation.context.append").isEmpty)
    XCTAssertEqual(call.master.requests.count, 1)
    let lost = await call.reports("send_failed")
    XCTAssertEqual(lost.map(\.kind), [.lost])
    let context = await until { await !call.reports("context_append").isEmpty }
    XCTAssertTrue(context)
    // Said once: the next delegation does not repeat it.
    let next = expectation(description: "next")
    call.master.asked = { next.fulfill() }
    call.pool.transports[1].event?(delegation("b", "Outra coisa"))
    await fulfillment(of: [next], timeout: 3)
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertFalse(call.pool.transports[1].sent("delegation.context.append", item: "b").contains("Custa 10 mil"))
    await call.controller.end()
  }

  /// Rebuilds the call and has the master's result go to it as call context, which GPT Live does not confirm; returns
  /// the rebuilt call's transport.
  private func resultAsContext(_ call: Resilient) async throws -> VoiceTestTransport {
    call.pool.confirms = false
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    call.pool.transports[0].event?(delegation("a", "Confira a sessão"))
    await fulfillment(of: [asked], timeout: 3)
    call.pool.transports[0].event?(.failed(.iceFailed))
    let rebuilt = await until { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    call.master.update?(.finished("Está tudo certo."))
    let sent = await until(3) { !call.pool.transports[1].sent("session.context.append").isEmpty }
    XCTAssertTrue(sent)
    return call.pool.transports[1]
  }

  /// An `error` naming the result's call context by its `event_id` is a refusal: the result waits for the next
  /// delegation of the new call, and the report names the command and GPT Live's call.
  func testRejectedContextWaitsForTheNextDelegation() async throws {
    let call = await resilient()
    let transport = try await resultAsContext(call)
    let id = try XCTUnwrap(transport.eventID("session.context.append"))
    transport.event?(.data(try JSONEncoder().encode(JSONValue.object(["type": .string("error"), "event_id": .string("event_srv"),
      "error": .object(["type": .string("invalid_request_error"), "code": .string("unknown_parameter"), "event_id": .string(id)])]))))
    let next = expectation(description: "next")
    call.master.asked = { next.fulfill() }
    transport.event?(delegation("b", "E agora?"))
    await fulfillment(of: [next], timeout: 3)
    let delivered = await until(3) { transport.sent("delegation.context.append", item: "b").contains("Resultado: Está tudo certo.") }
    XCTAssertTrue(delivered)
    let errors = await call.reports("service_error")
    let error = try XCTUnwrap(errors.first)
    XCTAssertEqual(error.failedCommand, "session.context.append")
    XCTAssertLessThan(try XCTUnwrap(error.failedCommandSeconds), 3)
    XCTAssertEqual(error.remoteCall, "test")
    await call.controller.end()
  }

  /// An `error` that names none of the app's commands (no `error.event_id`, or only the service's at the top) is not
  /// a refusal of the result: it is not sent again, and the report names no command.
  func testErrorWithoutTheAppsEventIDIsNotARefusal() async throws {
    let call = await resilient()
    let transport = try await resultAsContext(call)
    for json in [#"{"type":"error","event_id":"event_srv","error":{"type":"invalid_request_error","code":"unknown_parameter","event_id":null}}"#,
      #"{"type":"error","event_id":"event_srv","error":{"type":"server_error","code":"internal","event_id":"oc_0000000000000000"}}"#] {
      transport.event?(.data(Data(json.utf8)))
    }
    let next = expectation(description: "next")
    call.master.asked = { next.fulfill() }
    transport.event?(delegation("b", "E agora?"))
    await fulfillment(of: [next], timeout: 3)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertFalse(transport.sent("delegation.context.append", item: "b").contains("Está tudo certo"))
    let errors = await call.reports("service_error")
    XCTAssertEqual(errors.count, 2)
    XCTAssertTrue(errors.allSatisfy { $0.failedCommand == nil && $0.failedCommandSeconds == nil })
    await call.controller.end()
  }

  /// A call lost after its result went out but before GPT Live took every part of it hands the result to the
  /// rebuilt call, as call context; GPT Live taking it there is reported once.
  func testResultLostBeforeItsConfirmationReachesTheRebuiltCall() async throws {
    let call = await resilient()
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    let first = call.pool.transports[0]
    first.confirms = false
    first.event?(delegation("a", "Pesquise o preço do Mac Studio"))
    await fulfillment(of: [asked], timeout: 3)
    call.master.update?(.finished("Custa 10 mil reais."))
    let said = await until(3) { first.sent("delegation.context.append", item: "a").contains("Resultado: Custa 10 mil reais.") }
    XCTAssertTrue(said)
    first.event?(.failed(.iceFailed))
    let heard = await until(5) { call.pool.transports.count == 2
      && call.pool.transports[1].sent("session.context.append").contains("Resultado: Custa 10 mil reais.") }
    XCTAssertTrue(heard)
    let delivered = await until { await call.reports("context_append").count == 1 }
    XCTAssertTrue(delivered)
    XCTAssertEqual(call.master.requests.count, 1)
    await call.controller.end()
  }

  /// A result GPT Live took (every part confirmed) is not sent again after a loss.
  func testConfirmedResultIsNotSentAgainAfterALoss() async throws {
    let call = await resilient()
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    let first = call.pool.transports[0]
    first.event?(delegation("a", "Pesquise o preço do Mac Studio"))
    await fulfillment(of: [asked], timeout: 3)
    // In several parts, each confirmed.
    let result = String(repeating: "Custa 10 mil reais. ", count: 60)
    call.master.update?(.finished(result))
    let said = await until(3) { first.sent("delegation.context.append", item: "a") == "Resultado: " + result }
    XCTAssertTrue(said)
    first.event?(.failed(.iceFailed))
    let rebuilt = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertEqual(call.pool.transports[1].sent("session.context.append"), "")
    let delivered = await call.reports("context_append")
    XCTAssertTrue(delivered.isEmpty)
    await call.controller.end()
  }

  /// `session.started` naming another call than the creation's `Location` is reported, and the call goes on.
  func testSessionStartedNamingAnotherCallIsReported() async throws {
    let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
    let transport = VoiceTestTransport(), http = VoiceTestHTTP()
    transport.startedCall = "rtc_outra"
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }, diagnostics: outbox))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [answered], timeout: 3)
    XCTAssertEqual(controller.state.phase, .listening)
    let reported = await until { await outbox.pending().contains { $0.reason == "call_mismatch" } }
    XCTAssertTrue(reported)
    let pending = await outbox.pending()
    let mismatch = try XCTUnwrap(pending.first { $0.reason == "call_mismatch" })
    XCTAssertEqual(mismatch.kind, .tolerated)
    XCTAssertEqual(mismatch.code, "rtc_outra")
    XCTAssertEqual(mismatch.remoteCall, "test", "the Location's")
    await controller.end()
    transport.startedCall = "test"
    let again = expectation(description: "again")
    transport.answered = { again.fulfill() }
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await fulfillment(of: [again], timeout: 3)
    await controller.end()
    let mismatches = await outbox.pending().filter { $0.reason == "call_mismatch" }
    XCTAssertEqual(mismatches.count, 1, "the same ID is no mismatch")
  }

  /// The rebuilt call starts with the requests the master still has, and the same request delegated again is not
  /// sent twice: the new item carries its result.
  func testRebuiltCallCarriesRunningRequestsAndDoesNotRepeatThem() async throws {
    let call = await resilient()
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    call.pool.transports[0].event?(delegation("a", "Confira a sessão do Abacato."))
    await fulfillment(of: [asked], timeout: 3)
    call.pool.transports[0].event?(.failed(.dataChannelClosed))
    let rebuilt = await until { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    let offers = try await call.offers()
    XCTAssertEqual(offers.count, 2)
    let resumed = offers[1]["initial_items"]?.array?.last?.object?["content"]?.array?.first?.object?["text"]?.string
    XCTAssertTrue(resumed?.hasPrefix("Pedidos desta conversa já entregues ao agente e ainda em andamento") == true)
    XCTAssertTrue(resumed?.contains("- Confira a sessão do Abacato.") == true)
    XCTAssertNil(offers[0]["initial_items"], "a fresh call starts as before")
    // Same request, other spelling: not sent again.
    call.pool.transports[1].event?(delegation("b", "confira a sessao do abacato"))
    let told = await until { call.pool.transports[1].sent("delegation.context.append", item: "b").contains("já está com o agente") }
    XCTAssertTrue(told)
    XCTAssertEqual(call.master.requests.count, 1)
    call.master.update?(.finished("Tudo certo no Abacato."))
    let result = await until(3) { call.pool.transports[1].sent("delegation.context.append", item: "b").contains("Resultado: Tudo certo no Abacato.") }
    XCTAssertTrue(result)
    let repeats = await call.reports("delegation_repeat")
    XCTAssertEqual(repeats.count, 1)
    // Settled: the same words now are a new request.
    let again = expectation(description: "again")
    call.master.asked = { again.fulfill() }
    call.pool.transports[1].event?(delegation("c", "Confira a sessão do Abacato."))
    await fulfillment(of: [again], timeout: 3)
    XCTAssertEqual(call.master.requests.count, 2)
    await call.controller.end()
  }

  // MARK: Request built by the app (02/11, third wave)

  /// As the route sends them: the delegation's text is the transcript of the turn it names (`user_bidi_turn_id`), and
  /// that turn's `turn.done` comes after it.
  private func routeDelegation(_ id: String, _ text: String, turn: String) -> VoiceTransportEvent {
    .data(try! JSONEncoder().encode(JSONValue.object(["type": .string("delegation.created"), "item": .object([
      "type": .string("delegation"), "target": .string("client"), "id": .string(id), "handoff_id": .string("handoff_1"),
      "user_bidi_turn_id": .string(turn),
      "content": .array(text.isEmpty ? [] : [.object(["type": .string("input_text"), "text": .string(text)])])]),
      "offset_ms": .number(15_000)])))
  }
  private func spoken(_ role: String, _ id: String, _ text: String) -> VoiceTransportEvent {
    .data(try! JSONEncoder().encode(JSONValue.object(["type": .string("turn.done"),
      "turn": .object(["id": .string(id), "role": .string(role), "transcript": .string(text)])])))
  }
  private func piece(_ text: String) -> VoiceTransportEvent {
    .data(try! JSONEncoder().encode(JSONValue.object(["type": .string("input_transcript.added"),
      "item": .object(["id": .string(UUID().uuidString), "text": .string(text)])])))
  }

  /// The master gets his words plus the conversation it has not seen; a rebuilt call still knows only his words.
  func testRequestCarriesTheConversationSinceThePreviousDelegation() async throws {
    let call = await resilient()
    let transport = try XCTUnwrap(call.pool.transports.first)
    let first = expectation(description: "first")
    call.master.asked = { first.fulfill() }
    transport.event?(piece(" Quantas sessões estão abertas?"))
    transport.event?(routeDelegation("a", "Quantas sessões estão abertas?", turn: "t1"))
    await fulfillment(of: [first], timeout: 3)
    for event in [spoken("user", "t1", " Quantas sessões estão abertas?"), spoken("assistant", "a1", " Vou verificar."),
      spoken("assistant", "a2", " Há duas: Abacato e Misty.")] { transport.event?(event) }
    let second = expectation(description: "second")
    call.master.asked = { second.fulfill() }
    transport.event?(piece(" E a outra?"))
    transport.event?(routeDelegation("b", "E a outra?", turn: "t2"))
    await fulfillment(of: [second], timeout: 3)
    XCTAssertEqual(call.master.requests.map(\.text), ["Quantas sessões estão abertas?", """
      E a outra?

      Conversa por voz desde o pedido anterior (transcrição, pode ter erros):
      Voz: Vou verificar.
      Voz: Há duas: Abacato e Misty.
      """])
    XCTAssertEqual(call.master.requests.map(\.delivery), [.steer, .steer])
    XCTAssertEqual(call.master.requests.map(\.screen), [nil, nil])
    transport.event?(.failed(.dataChannelClosed))
    let rebuilt = await until { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    let carried = try await call.offers()[1]["initial_items"]?.array?.last?.object?["content"]?.array?.first?.object?["text"]?.string
    XCTAssertTrue(carried?.hasSuffix("- Quantas sessões estão abertas?\n- E a outra?") == true, carried ?? "")
    await call.controller.end()
  }

  /// A delegation without text is what he is saying, else what he last said; only with neither GPT Live hears to ask
  /// again. His words, not a JSON field, queue it.
  func testDelegationWithoutTextKeepsWhatAlexandreSaid() async throws {
    let call = await resilient()
    let transport = try XCTUnwrap(call.pool.transports.first)
    let first = expectation(description: "pending speech")
    call.master.asked = { first.fulfill() }
    transport.event?(piece(" Coloca na fila"))
    transport.event?(piece(" os testes do Mac"))
    transport.event?(routeDelegation("u1", "", turn: "t1"))
    await fulfillment(of: [first], timeout: 3)
    transport.event?(spoken("user", "t1", " Coloca na fila os testes do Mac"))
    transport.event?(spoken("user", "t2", " Roda o lint"))
    let second = expectation(description: "last turn")
    call.master.asked = { second.fulfill() }
    transport.event?(routeDelegation("u2", "", turn: "t2"))
    await fulfillment(of: [second], timeout: 3)
    XCTAssertEqual(call.master.requests.map(\.text), ["Coloca na fila os testes do Mac", "Roda o lint"])
    XCTAssertEqual(call.master.requests.map(\.delivery), [.queue, .steer])
    transport.event?(routeDelegation("u3", "", turn: "t3"))
    let answered = await until { !transport.sent("delegation.context.append", item: "u3").isEmpty }
    XCTAssertTrue(answered)
    XCTAssertEqual(transport.sent("delegation.context.append", item: "u3"), "Não consegui ler esse pedido. Peça para Alexandre repetir.")
    XCTAssertEqual(call.master.requests.count, 2)
    let unreadable = await call.reports("invalid_event")
    XCTAssertEqual(unreadable.map(\.code), ["delegation.created", "delegation.created", "delegation.created"])
    await call.controller.end()
  }

  // MARK: Moderation reset (01/11)

  /// A voice memory server that records its RPCs and answers `context` with what it holds.
  private actor ModerationMemoryServer {
    var calls: [String] = []
    /// The `at` each reset carried.
    var resets: [Double?] = []
    var summary = "Memória sintética antiga: palavra jambo."
    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
      let method = request.url!.lastPathComponent
      calls.append(method)
      if method == "reset" {
        summary = ""
        resets.append(try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data("{}".utf8))
          .object?["input"]?.object?["at"]?.number)
      }
      let body = switch method {
      case "info": #"{"output":{"version":2,"storage":"kv","contextFormat":"initial_items","scopes":["global"]}}"#
      case "context":
        #"{"output":{"version":2,"scope":"global","summary":"\#(summary)","turns":[],"approxTokens":30,"updatedAt":0,"truncated":false}}"#
      default: #"{"output":{}}"#
      }
      return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
  }
  private struct Moderated {
    let controller: VoiceController
    let pool: VoiceTransportPool
    let master: VoiceTestMaster
    let http: VoiceFlakyHTTP
    let cues: VoiceTestCues
    let outbox: VoiceDiagnosticsOutbox
    let server: ModerationMemoryServer
    let memory: VoiceMemoryStore
    let root: URL
    func texts(_ offer: Int) async throws -> [String] {
      let offers = await http.requests.filter { $0.url?.path.hasSuffix("/calls") == true }
      let session = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(offers[offer].httpBody)).object?["session"]?.object
      return session?["initial_items"]?.array?.flatMap { $0.object?["content"]?.array ?? [] }
        .compactMap { $0.object?["text"]?.string } ?? []
    }
    func reports(_ reason: String) async -> [VoiceDiagnostic] { await outbox.pending().filter { $0.reason == reason } }
  }
  private func moderated(_ policy: VoiceRecoveryPolicy = .init(backoff: [0.05])) async throws -> Moderated {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/voice-moderation-" + UUID().uuidString)
    let server = ModerationMemoryServer()
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4180")!)
    let memory = VoiceMemoryStore(client: OpenCodeClient(configuration: configuration, transport: { try await server.respond($0) }),
      root: root)
    let http = VoiceFlakyHTTP(), pool = VoiceTransportPool(), master = VoiceTestMaster(), cues = VoiceTestCues()
    let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
    let controller = VoiceController(testing: .init(transport: { pool.make($0) },
      master: { update in master.update = update; return master }, request: { try await http.respond($0) },
      memory: memory, policy: policy, network: VoiceTestPath(), cues: cues, diagnostics: outbox))
    controller.start(sessions: SessionStore(configuration: configuration))
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    return Moderated(controller: controller, pool: pool, master: master, http: http, cues: cues, outbox: outbox,
      server: server, memory: memory, root: root)
  }
  private let moderation = Data(#"{"type":"error","error":{"type":"content_filter","code":"content_filter","message":"The generation was stopped due to moderation."}}"#.utf8)
  private let serviceClosed = Data(#"{"type":"session.closed"}"#.utf8)

  /// A moderation error followed by the end of the session (here `session.closed`) clears voice memory (here and on
  /// the server) and what a rebuilt call would carry, and starts one empty call: the same instructions, no history, no
  /// carried request, no old result, nothing of what was being said. One sound; the notice stays through every phase
  /// until the call ends.
  func testModerationThatEndsTheSessionClearsTheContextOnceAndStartsAnEmptyCall() async throws {
    let call = try await moderated()
    defer { try? FileManager.default.removeItem(at: call.root) }
    let initial = try await call.texts(0)
    XCTAssertTrue(initial.contains { $0.contains("palavra jambo") })
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    let first = call.pool.transports[0]
    first.event?(delegation("a", "Pedido da conversa antiga"))
    await fulfillment(of: [asked], timeout: 3)
    first.event?(.data(Data(#"{"type":"turn.done","turn":{"id":"before","role":"user","transcript":"Fala antiga."}}"#.utf8)))
    first.event?(.data(Data(#"{"type":"input_transcript.added","item":{"id":"item-cut","text":"Fala cortada"}}"#.utf8)))
    first.event?(.data(moderation))
    // Until the session ends, the moderation is only pending: the call goes on and what it says is captured.
    XCTAssertFalse(call.controller.state.contextCleared)
    first.event?(.data(Data(#"{"type":"turn.done","turn":{"id":"after","role":"assistant","transcript":"Fala moderada."}}"#.utf8)))
    let cleared = Date.now.timeIntervalSince1970 * 1000
    first.event?(.data(serviceClosed))
    XCTAssertTrue(call.controller.state.contextCleared)
    let rebuilt = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    XCTAssertTrue(first.closed)
    let released = await until { await call.http.count("DELETE") >= 1 }
    XCTAssertTrue(released, "the moderated call's lease is released")
    let calls = await call.server.calls
    XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
    // The reset carries when this iPhone cleared its memory, on the clock of its turns.
    let resets = await call.server.resets
    let at = try XCTUnwrap(resets.first ?? nil)
    XCTAssertGreaterThanOrEqual(at, cleared)
    XCTAssertLessThanOrEqual(at, Date.now.timeIntervalSince1970 * 1000)
    let fresh = try await call.texts(1)
    XCTAssertTrue(fresh.isEmpty, "the new call starts with an empty window")
    let offers = await call.http.requests.filter { $0.url?.path.hasSuffix("/calls") == true }
    let instructions = try offers.map {
      try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap($0.httpBody)).object?["session"]?.object?["instructions"]?.string
    }
    XCTAssertEqual(instructions[0], instructions[1], "the service instructions stay")
    // The old request's result is not narrated into the empty call; the Mestra is not stopped or asked again.
    call.master.update?(.finished("Resultado da conversa antiga."))
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertTrue(call.pool.transports[1].frames.isEmpty)
    XCTAssertEqual(call.master.requests.count, 1)
    XCTAssertFalse(call.master.stopped)
    // One sound for the reset; the restore tone is the rebuilt call's.
    XCTAssertEqual(call.cues.played, [.contextCleared, .restored])
    let pending = await call.reports("moderation_pending")
    XCTAssertEqual(pending.map(\.kind), [.tolerated])
    let reset = await call.reports("context_reset")
    XCTAssertEqual(reset.map(\.kind), [.lost])
    XCTAssertEqual(reset.first?.code, "content_filter/content_filter")
    let closed = await call.reports("session_closed")
    XCTAssertTrue(closed.isEmpty, "the session's end is the moderation's, not a loss of its own")
    // The notice stays through the new call's phases.
    call.pool.transports[1].event?(.data(Data(#"{"type":"output_transcript.added","item":{"id":"o","text":"Oi."}}"#.utf8)))
    XCTAssertEqual(call.controller.state.phase, .speaking)
    XCTAssertTrue(VoiceBarState(voice: call.controller.state, elapsed: 1).contextCleared)
    // Nothing of the old conversation is left to send.
    await call.memory.stop()
    let buffer = try await VoiceMemoryBuffer(server: "http://127.0.0.1:4180", root: call.root).snapshot()
    XCTAssertFalse(buffer.pending.contains { $0.id.hasSuffix(":before") || $0.id.hasSuffix(":after") || $0.id.contains(":partial-") })
    XCTAssertTrue(buffer.context.turns.isEmpty)
    await call.controller.end()
    XCTAssertFalse(call.controller.state.contextCleared, "it leaves with the call")
  }

  /// A moderation that only cut the speech: the session outlives the window, so the call, its transport and its
  /// memory go on and a non-fatal report follows. A session that ends after the window is an ordinary loss: the
  /// rebuilt call keeps the memory.
  func testModerationThatOnlyCutsTheSpeechKeepsTheCallAndItsMemory() async throws {
    let call = try await moderated(.init(backoff: [0.05], moderationWindow: 0.3))
    defer { try? FileManager.default.removeItem(at: call.root) }
    let first = call.pool.transports[0]
    first.event?(.data(moderation))
    let survived = await until { await !call.reports("moderation_nonfatal").isEmpty }
    XCTAssertTrue(survived)
    XCTAssertEqual(call.controller.state.phase, .listening)
    XCTAssertFalse(call.controller.state.contextCleared)
    XCTAssertEqual(call.pool.transports.count, 1)
    XCTAssertFalse(first.closed)
    XCTAssertFalse(call.cues.played.contains(.contextCleared))
    let nonFatal = await call.reports("moderation_nonfatal")
    XCTAssertEqual(nonFatal.map(\.kind), [.tolerated])
    XCTAssertEqual(nonFatal.first?.code, "content_filter/content_filter")
    // The call still delegates.
    let asked = expectation(description: "asked")
    call.master.asked = { asked.fulfill() }
    first.event?(delegation("depois", "Confira as sessões"))
    await fulfillment(of: [asked], timeout: 3)
    first.event?(.data(serviceClosed))
    let rebuilt = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    XCTAssertFalse(call.controller.state.contextCleared)
    let lost = await call.reports("session_closed")
    XCTAssertEqual(lost.map(\.kind), [.lost])
    let calls = await call.server.calls
    XCTAssertFalse(calls.contains("reset"))
    let resumed = try await call.texts(1)
    XCTAssertTrue(resumed.contains { $0.contains("palavra jambo") }, "the rebuilt call keeps the memory")
    await call.controller.end()
  }

  /// `session.closed` whose reason names moderation clears the context even without a moderation error.
  func testSessionClosedForContentClearsTheContext() async throws {
    let call = try await moderated()
    defer { try? FileManager.default.removeItem(at: call.root) }
    call.pool.transports[0].event?(.data(Data(#"{"type":"session.closed","reason":"content"}"#.utf8)))
    XCTAssertTrue(call.controller.state.contextCleared)
    let rebuilt = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    let fresh = try await call.texts(1)
    XCTAssertTrue(fresh.isEmpty)
    let reset = await call.reports("context_reset")
    XCTAssertEqual(reset.map(\.code), ["content"])
    await call.controller.end()
  }

  /// Moderated again on the empty call before it answered normally: no second reset or rebuild, a clear failure.
  func testModerationOfTheEmptyCallFailsInsteadOfLooping() async throws {
    let call = try await moderated()
    defer { try? FileManager.default.removeItem(at: call.root) }
    call.pool.transports[0].event?(.data(moderation))
    call.pool.transports[0].event?(.data(serviceClosed))
    let rebuilt = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    call.pool.transports[1].event?(.data(moderation))
    // An answer between the error and the end belongs to the moderated session.
    call.pool.transports[1].event?(.data(Data(#"{"type":"turn.done","turn":{"id":"cut","role":"assistant","transcript":"Resposta."}}"#.utf8)))
    call.pool.transports[1].event?(.failed(.dataChannelClosed))
    let failed = await until { call.controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertTrue(call.controller.state.contextCleared, "the notice stays with the failure")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(call.pool.transports.count, 2)
    let calls = await call.server.calls
    XCTAssertEqual(calls.filter { $0 == "reset" }.count, 1)
    XCTAssertEqual(call.cues.played.filter { $0 == .contextCleared }.count, 1)
    let repeated = await until { await !call.reports("moderated").isEmpty }
    XCTAssertTrue(repeated)
    await call.controller.end()
  }

  /// After the empty call answered normally, a later moderation may clear again (its own new context); the data
  /// channel closing ends the session as `session.closed` does.
  func testModerationAfterANormalAnswerClearsAgain() async throws {
    let call = try await moderated()
    defer { try? FileManager.default.removeItem(at: call.root) }
    call.pool.transports[0].event?(.data(moderation))
    call.pool.transports[0].event?(.failed(.dataChannelClosed))
    _ = await until(5) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    call.pool.transports[1].event?(.data(Data(#"{"type":"turn.done","turn":{"id":"ok","role":"assistant","transcript":"Resposta normal."}}"#.utf8)))
    call.pool.transports[1].event?(.data(moderation))
    call.pool.transports[1].event?(.failed(.dataChannelClosed))
    let again = await until(5) { call.pool.transports.count == 3 && call.controller.state.phase == .listening }
    XCTAssertTrue(again)
    XCTAssertEqual(call.cues.played.filter { $0 == .contextCleared }.count, 2)
    await call.controller.end()
  }

  /// Without memory or carried requests there is nothing to clear: a moderation that ends the session fails the call.
  func testModerationWithoutContextFails() async throws {
    let call = await resilient()
    call.pool.transports[0].event?(.data(moderation))
    call.pool.transports[0].event?(.data(serviceClosed))
    let failed = await until { call.controller.state.phase == .failed }
    XCTAssertTrue(failed)
    XCTAssertFalse(call.controller.state.contextCleared)
    XCTAssertEqual(call.pool.transports.count, 1)
    await call.controller.end()
  }

  // MARK: Ending (02/11)

  /// Ending asks GPT Live to close the session and waits for `session.closed` before the transport and the lease go;
  /// that close neither reconnects nor reports a loss. The microphone stops at once.
  func testEndClosesTheSessionAndWaitsForItsConfirmation() async throws {
    let pool = VoiceTransportPool(), http = VoiceFlakyHTTP(), path = VoiceTestPath()
    pool.answersClose = false
    let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
    let controller = VoiceController(testing: .init(transport: { pool.make($0) }, master: { _ in VoiceTestMaster() },
      request: { try await http.respond($0) }, policy: .init(backoff: [0.05], closeWait: 30), network: path,
      cues: VoiceTestCues(), diagnostics: outbox))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let ready = await until { controller.state.phase == .listening }
    XCTAssertTrue(ready)
    let transport = pool.transports[0]
    let ending = Task { await controller.end() }
    let asked = await until { transport.types == ["session.close"] }
    XCTAssertTrue(asked)
    XCTAssertTrue(transport.muted)
    XCTAssertFalse(transport.closed, "the transport waits for the service")
    let releasedEarly = await http.count("DELETE")
    XCTAssertEqual(releasedEarly, 0)
    transport.event?(.data(Data(#"{"type":"session.closed","reason":"client_request","usage":{"audio_duration_ms":4200}}"#.utf8)))
    await ending.value
    XCTAssertEqual(controller.state.phase, .idle)
    XCTAssertTrue(transport.closed)
    let released = await http.count("DELETE")
    XCTAssertEqual(released, 1)
    XCTAssertEqual(pool.transports.count, 1, "no reconnection")
    let reported = await until { await outbox.pending().contains { $0.reason == "user_end" } }
    XCTAssertTrue(reported)
    try await Task.sleep(for: .milliseconds(100))
    let reasons = await outbox.pending().map(\.reason)
    XCTAssertEqual(reasons, ["user_end"], "the close is neither a loss nor a session_closed")
  }

  /// Without `session.closed`, the data channel closing ends the wait; without either, the wait runs out.
  func testEndStopsWaitingWhenTheChannelClosesOrTheWaitRunsOut() async throws {
    for channelCloses in [true, false] {
      let pool = VoiceTransportPool(), http = VoiceFlakyHTTP()
      pool.answersClose = false
      let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
      let controller = VoiceController(testing: .init(transport: { pool.make($0) }, master: { _ in VoiceTestMaster() },
        request: { try await http.respond($0) }, policy: .init(backoff: [0.05], closeWait: channelCloses ? 30 : 0.2),
        network: VoiceTestPath(), cues: VoiceTestCues(), diagnostics: outbox))
      controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
      let ready = await until { controller.state.phase == .listening }
      XCTAssertTrue(ready)
      let transport = pool.transports[0]
      let ending = Task { await controller.end() }
      if channelCloses {
        _ = await until { transport.types == ["session.close"] }
        transport.event?(.failed(.dataChannelClosed))
      }
      let ended = await until { controller.state.phase == .idle }
      XCTAssertTrue(ended)
      await ending.value
      XCTAssertTrue(transport.closed)
      XCTAssertEqual(pool.transports.count, 1)
      let reported = await until { await outbox.pending().contains { $0.reason == "user_end" } }
      XCTAssertTrue(reported)
      try await Task.sleep(for: .milliseconds(100))
      let reasons = await outbox.pending().map(\.reason)
      XCTAssertEqual(reasons, ["user_end"], "the channel closing is not a loss")
    }
  }

  /// What was said since each role's last `turn.done` is kept as an interrupted turn when the call ends: nothing
  /// arrives after `session.close`, and the user's `turn.done` waits for the assistant's next turn. A turn already
  /// completed is not written twice.
  func testEndKeepsWhatWasSaidSinceTheLastTurnInMemory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode/voice-partial-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:4180")!)
    // An older server: every capture stays in the local buffer, where the test reads it.
    let memory = VoiceMemoryStore(client: OpenCodeClient(configuration: configuration, transport: { request in
      (Data(#"{"output":{"version":1}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }), root: root)
    let transport = VoiceTestTransport()
    let http = VoiceTestHTTP()
    let answered = expectation(description: "answered")
    transport.answered = { answered.fulfill() }
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }, memory: memory))
    controller.start(sessions: SessionStore(configuration: configuration))
    await fulfillment(of: [answered], timeout: 3)
    for json in [
      #"{"type":"output_transcript.added","item":{"id":"o1","text":"Resposta"}}"#,
      #"{"type":"turn.done","turn":{"id":"t1","role":"assistant","transcript":"Resposta completa."}}"#,
      #"{"type":"output_transcript.added","item":{"id":"o2","text":"Estou"}}"#,
      #"{"type":"output_transcript.added","item":{"id":"o2","text":" conferindo"}}"#,
      #"{"type":"input_transcript.added","item":{"id":"i1","text":" Espera,"}}"#,
      #"{"type":"input_transcript.added","item":{"id":"i1","text":" outra coisa"}}"#,
    ] { transport.event?(.data(Data(json.utf8))) }
    await controller.end()
    await memory.stop()
    let recovered = try await VoiceMemoryBuffer(server: configuration.url.absoluteString, root: root).snapshot()
    XCTAssertEqual(recovered.context.turns.map(\.text), ["Resposta completa.", "Estou conferindo", "Espera, outra coisa"])
    XCTAssertEqual(recovered.context.turns.map(\.role), [.assistant, .assistant, .user])
    XCTAssertEqual(recovered.context.turns.map { $0.interrupted == true }, [false, true, true])
    XCTAssertEqual(recovered.context.turns.dropFirst().map { $0.id.contains(":partial-") }, [true, true])
    if case .some(.end) = recovered.pending.last {} else { XCTFail("End must follow the kept turns") }
  }

  /// ICE flapping does not stretch the grace; ICE coming back inside it keeps the same call.
  func testIceFlappingKeepsTheGraceAndARecoveryKeepsTheCall() async throws {
    let call = await resilient(.init(mediaGrace: 1, backoff: [0.05]))
    let first = call.pool.transports[0]
    first.event?(.disconnected)
    XCTAssertEqual(call.controller.state.phase, .reconnecting)
    try await Task.sleep(for: .milliseconds(600))
    first.event?(.disconnected)
    // Rebuilt 1 s after the first disconnection (about 0.45 s from now), not 1 s after the second.
    let rebuilt = await until(0.7) { call.pool.transports.count == 2 }
    XCTAssertTrue(rebuilt)
    let ready = await until { call.controller.state.phase == .listening }
    XCTAssertTrue(ready)
    let second = call.pool.transports[1]
    second.event?(.disconnected)
    try await Task.sleep(for: .milliseconds(200))
    second.event?(.connected)
    XCTAssertEqual(call.controller.state.phase, .listening)
    try await Task.sleep(for: .milliseconds(1200))
    XCTAssertEqual(call.pool.transports.count, 2, "recovered inside the grace: no rebuild")
    XCTAssertFalse(second.closed)
    let recovered = await call.reports("ice_recovered")
    XCTAssertEqual(recovered.count, 1)
    let disconnected = await call.reports("ice_disconnected")
    XCTAssertEqual(disconnected.map(\.kind), [.tolerated, .lost, .tolerated])
    await call.controller.end()
  }

  /// The network coming back (Wi-Fi to 5G) leaves WebRTC only the handover window before the rebuild.
  func testNetworkReturnLeavesOnlyTheHandoverWindow() async throws {
    let call = await resilient(.init(mediaGrace: 30, handoverGrace: 0.2, backoff: [0.05]))
    call.path.set(VoicePath(satisfied: false))
    call.pool.transports[0].event?(.disconnected)
    XCTAssertEqual(call.controller.state.phase, .offline)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(call.pool.transports.count, 1, "no rebuild while offline inside the grace")
    call.path.set(VoicePath(satisfied: true, interfaces: ["cellular:pdp_ip0"]))
    XCTAssertEqual(call.controller.state.phase, .reconnecting)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(call.pool.transports.count, 1, "WebRTC first gets the handover window")
    let rebuilt = await until(2) { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    let changed = await call.reports("network_changed")
    XCTAssertEqual(changed.map(\.kind), [.tolerated, .lost])
    await call.controller.end()
  }

  /// A lease renewal answered 500 (the proxy's Redis away for a moment) is retried and reported once.
  func testServerErrorOnRenewalIsRetriedAndReportedOnce() async throws {
    let call = await resilient(.init(renewal: 0.05, renewalRetry: 0.05), http: VoiceFlakyHTTP(renewalOutages: 3))
    let renewed = await until { await call.http.count("PUT") >= 6 }
    XCTAssertTrue(renewed)
    XCTAssertEqual(call.controller.state.phase, .listening)
    XCTAssertEqual(call.pool.transports.count, 1)
    let retries = await call.reports("lease_retry")
    XCTAssertEqual(retries.map(\.code), ["http_500"])
    await call.controller.end()
  }

  /// The transport's statistics only feed the quality summary: the reports of the call's end (here `lost` and
  /// `ended`) carry it, across a rebuilt link whose counters start again; other reports and the event trail do not.
  func testEndReportsCarryTheCallsAudioQualityAcrossLinks() async throws {
    let call = await resilient()
    let first = try XCTUnwrap(call.pool.transports.first)
    let headset = VoiceAudioRoute(inputs: ["BluetoothHFP"], outputs: ["BluetoothHFP"], sampleRate: 16_000)
    first.event?(.quality(VoiceQualitySample(at: 0, route: headset)))
    first.event?(.quality(Self.reading(0, received: 0, played: 0, concealed: 0)))
    first.event?(.quality(Self.reading(5, received: 250, played: 240_000, concealed: 12_000)))
    first.event?(.quality(Self.reading(10, received: 500, played: 480_000, concealed: 12_000)))
    first.event?(.data(Data(#"{"type":"error","error":{"type":"server_error","code":"internal"}}"#.utf8)))
    first.event?(.failed(.iceFailed))
    let rebuilt = await until { call.pool.transports.count == 2 && call.controller.state.phase == .listening }
    XCTAssertTrue(rebuilt)
    let second = call.pool.transports[1]
    second.event?(.quality(Self.reading(20, received: 10, played: 9_600, concealed: 0)))
    second.event?(.quality(Self.reading(25, received: 260, played: 249_600, concealed: 0)))
    await call.controller.end()
    let ended = await until { await call.reports("user_end").count == 1 }
    XCTAssertTrue(ended)

    let reports = await call.outbox.pending()
    let lost = try XCTUnwrap(reports.first { $0.reason == "ice_failed" }?.quality)
    XCTAssertEqual(lost.windows, 2); XCTAssertEqual(lost.badWindows, 1); XCTAssertEqual(lost.links, 1)
    XCTAssertEqual(lost.concealedPct, 2.5)
    XCTAssertEqual(lost.worst?.cause, "concealed"); XCTAssertEqual(lost.worst?.atSeconds, 5)
    XCTAssertEqual(lost.routes, [headset])
    let whole = try XCTUnwrap(reports.first { $0.reason == "user_end" }?.quality)
    XCTAssertEqual(whole.windows, 3); XCTAssertEqual(whole.links, 2); XCTAssertEqual(whole.seconds, 15)
    XCTAssertEqual(whole.concealedPct, 1.67)
    let tolerated = reports.filter { $0.kind == .tolerated }
    XCTAssertFalse(tolerated.isEmpty)
    XCTAssertTrue(tolerated.allSatisfy { $0.quality == nil })
    XCTAssertFalse(reports.contains { $0.events.contains { $0.contains("quality") } })
  }
  /// One link's cumulative inbound counters at `at`: 48 kHz audio, 20 ms packets, 10 ms of jitter.
  private static func reading(_ at: TimeInterval, received: Double, played: Double, concealed: Double) -> VoiceQualitySample {
    var sample = VoiceQualitySample(at: at)
    sample.packetsReceived = received; sample.packetsLost = 0; sample.totalSamplesReceived = played
    sample.concealedSamples = concealed; sample.silentConcealedSamples = 0; sample.jitter = 0.01
    return sample
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
    transports[0].event(.failed(.iceFailed))
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

  /// One real muted call through the controller and the real transport, about 12 s connected: confirms that libwebrtc
  /// M147 returns the statistics the quality summary reads. Opt-in only; no speech, no delegation.
  func testExplicitSilentLiveQuality() async throws {
    #if targetEnvironment(simulator)
    guard ProcessInfo.processInfo.environment["OPENCODE_TEST_LIVE_VOICE_QUALITY"] == "1" else {
      throw XCTSkip("Explicit one-call muted simulator quality probe only; never enabled by the normal suite.")
    }
    let http = LiveFlakyHTTP()
    let outbox = VoiceDiagnosticsOutbox(url: FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json"))
    let controller = VoiceController(testing: .init(transport: { SilentLiveTransport(event: $0) },
      master: { _ in VoiceTestMaster() }, request: { try await http.perform($0) }, diagnostics: outbox))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let ready = await until(25) { controller.state.phase == .listening }
    XCTAssertTrue(ready, controller.detail)
    guard ready else { await controller.end(); return }
    // The baseline at connection and two readings after it.
    try await Task.sleep(for: .seconds(2 * VoiceQualityMeter.interval + 2))
    await controller.end()
    let released = await until(10) { await http.releases.count >= 1 }
    let quality = await outbox.pending().first { $0.reason == "user_end" }?.quality
    let data = try JSONEncoder().encode(quality)
    print("voice-quality-live", String(decoding: data, as: UTF8.self))
    let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    evidence.name = "voice-quality-live"; evidence.lifetime = .keepAlways; add(evidence)
    let creates = await http.creates, releases = await http.releases
    XCTAssertTrue(released)
    XCTAssertEqual(creates, [201]); XCTAssertEqual(releases, [204])
    // A silent call receives no RTP, and libwebrtc reports no `inbound-rtp` before the first packet (03/11: no
    // concealment, jitter or buffer here); what was sent, the server's RTCP, the pair and the route are there.
    let measured = try XCTUnwrap(quality)
    XCTAssertGreaterThanOrEqual(measured.windows, 2); XCTAssertEqual(measured.links, 1)
    XCTAssertNotNil(measured.lossOutPct); XCTAssertNotNil(measured.rttMs)
    XCTAssertFalse(measured.paths.isEmpty); XCTAssertFalse(measured.routes.isEmpty)
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
    // Turns keep their speaker; the memory summary and the Mestra state go as developer messages.
    XCTAssertEqual(Set(metrics.roles).subtracting(["developer"]), ["assistant", "user"])
    #else
    throw XCTSkip("No physical device live probing in this suite.")
    #endif
  }

  /// Asks the real GPT Live whether it takes an image: one muted call, one `conversation.item.create` with
  /// `input_image`, then the raw events. Opt-in only.
  func testExplicitSilentLiveImageInput() async throws {
    #if targetEnvironment(simulator)
    guard ProcessInfo.processInfo.environment["OPENCODE_TEST_LIVE_VOICE_IMAGE"] == "1" else {
      throw XCTSkip("Explicit one-call muted simulator image probe only.")
    }
    let recorder = LiveEventRecorder()
    let transport = SilentLiveTransport { event in recorder.receive(event) }
    let signal = VoiceSignaling()
    let sdp = try await transport.offer()
    let (lease, reservation) = try await URLSession.shared.data(for: signal.leaseRequest(method: "POST"))
    _ = try signal.parseLease(lease, status: (reservation as? HTTPURLResponse)?.statusCode ?? 0)
    do {
      let (data, result) = try await URLSession.shared.data(for: signal.offerRequest(sdp: sdp,
        instructions: "Teste silencioso de entrada de imagem. Não fale."))
      try await transport.answer(VoiceSignaling.parseAnswer(data, response: XCTUnwrap(result as? HTTPURLResponse)))
      for _ in 0..<100 where !recorder.ready { try await Task.sleep(for: .milliseconds(100)) }
      XCTAssertTrue(recorder.ready)
      let pixel = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA="
      let image = JSONValue.object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64," + pixel)])
      // The Realtime item and the only context event this protocol lists, each with an image.
      let attempts = [
        JSONValue.object(["type": .string("conversation.item.create"), "item": .object([
          "type": .string("message"), "role": .string("user"), "content": .array([image])])]),
        JSONValue.object(["type": .string("session.context.append"), "content": .array([image])]),
      ]
      let before = recorder.events.count
      for attempt in attempts {
        try await transport.send(JSONEncoder().encode(attempt))
        try await Task.sleep(for: .seconds(4))
      }
      let after = Array(recorder.events.dropFirst(before))
      let evidence = XCTAttachment(data: try JSONEncoder().encode(["before": recorder.events.prefix(before).map { $0 },
        "after": after]), uniformTypeIdentifier: "public.json")
      evidence.name = "voice-image-live"; evidence.lifetime = .keepAlways; add(evidence)
    } catch {
      await transport.close()
      _ = try? await URLSession.shared.data(for: signal.leaseRequest(method: "DELETE"))
      throw error
    }
    await transport.close()
    let (_, release) = try await URLSession.shared.data(for: signal.leaseRequest(method: "DELETE"))
    XCTAssertEqual((release as? HTTPURLResponse)?.statusCode, 204)
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
        let (data, result) = try await URLSession.shared.data(for: signal.offerRequest(sdp: sdp, instructions: "Teste silencioso do catálogo de vozes.", voice: voice))
        let response = try XCTUnwrap(result as? HTTPURLResponse)
        let accepted = response.statusCode == 201
        if accepted { _ = try VoiceSignaling.parseAnswer(data, response: response) }
        let rejected = VoiceProtocol.rejectsVoice(data, status: response.statusCode)
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

  // StartVoiceIntent keeps the process alive with settled(within:) until the call can listen.
  func testLaunchSettlesWhenTheCallListens() async {
    let transport = VoiceTestTransport()
    let http = VoiceTestHTTP()
    let controller = VoiceController(testing: .init(transport: { event in transport.event = event; return transport },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }))
    controller.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    XCTAssertEqual(controller.state.phase, .connecting)
    await controller.settled(within: .seconds(5))
    XCTAssertEqual(controller.state.phase, .listening)
    XCTAssertFalse(controller.liveActivityActive, "fakes never request a Live Activity")
    await controller.end()
  }
  func testLaunchSettlesOnFailureAndOnItsDeadline() async {
    let http = VoiceTestHTTP()
    let denied = VoiceController(testing: .init(transport: { _ in VoiceTestTransport() },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }, permission: false))
    denied.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    await denied.settled(within: .seconds(5))
    XCTAssertEqual(denied.state.phase, .failed)
    await denied.end()

    let silent = VoiceTestTransport()
    let stalled = VoiceController(testing: .init(transport: { _ in silent },
      master: { _ in VoiceTestMaster() }, request: { try await http.respond($0) }))
    stalled.start(sessions: SessionStore(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)))
    let started = ContinuousClock.now
    await stalled.settled(within: .milliseconds(300))
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    XCTAssertEqual(stalled.state.phase, .connecting)
    await stalled.end()
  }
}
