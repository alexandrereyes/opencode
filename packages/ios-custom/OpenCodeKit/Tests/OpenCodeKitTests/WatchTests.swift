import Foundation
import Network
import Testing

@testable import OpenCodeKit

// MARK: Contract decoding

private let stateJSON = """
  {"state":{"v":1,"updatedAt":1793112000000,"host":"MacBook Pro",
   "counts":{"working":2,"question":1,"permission":1,"failed":0,"idle":1},"activeTotal":4,
   "focus":{"sessionID":"s1","title":"Live Activity no iOS","project":"ios","directory":"/r/ios",
            "startedAt":1793111800000,"progress":{"done":2,"total":3,"unit":"subagents"}},
   "attention":[
     {"sessionID":"s2","title":"Escolher banco do cache","project":"core","directory":"/r/core","kind":"question",
      "since":1793111820000,"text":"Qual banco usar no cache das sessões?","requestID":"req_q"},
     {"sessionID":"s3","title":"Rodar testes","project":"core","directory":"/r/core","kind":"permission",
      "since":1793111900000}],
   "attentionTotal":2,
   "sessions":[
     {"sessionID":"s2","title":"Escolher banco do cache","project":"core","directory":"/r/core","status":"question"},
     {"sessionID":"s1","title":"Live Activity no iOS","project":"ios","directory":"/r/ios","status":"working",
      "progress":{"done":2,"total":3,"unit":"subagents"}},
     {"sessionID":"s3","title":"Rodar testes","project":"core","directory":"/r/core","status":"permission"},
     {"sessionID":"s4","title":"Deploy no Swarm","project":"infra","directory":"/r/infra","status":"working"}]},
   "host":"MacBook Pro"}
  """

@Suite struct WatchContractTests {
  @Test func decodesStateWithOptionalRequestID() throws {
    let snapshot = try JSONDecoder().decode(WatchStateSnapshot.self, from: Data(stateJSON.utf8))
    let state = try #require(snapshot.state)
    #expect(snapshot.host == "MacBook Pro")
    #expect(state.attention.map(\.requestID) == ["req_q", nil])
    #expect(state.complicationLine == "2 para você")
    #expect(state.complicationDetail == "1 pergunta · 1 permissão · 2 trabalhando")
  }

  @Test func decodesNullState() throws {
    let snapshot = try JSONDecoder().decode(WatchStateSnapshot.self, from: Data(#"{"state":null,"host":"Mac"}"#.utf8))
    #expect(snapshot.state == nil)
  }

  @Test func decodesPairingAndRoundTripsThroughWatchConnectivity() throws {
    let json = """
      {"deviceID":"w1","deviceToken":"tok","gatewayURL":"https://watch-mac.alexandrem.com.br",
       "access":{"clientId":"id.access","clientSecret":"secret"},"voice":{"voiceID":"rio"}}
      """
    let pairing = try JSONDecoder().decode(WatchPairing.self, from: Data(json.utf8))
    #expect(pairing.gatewayURL.host() == "watch-mac.alexandrem.com.br")
    #expect(WatchPairing.from(payload: try pairing.transferPayload()) == pairing)
    #expect(WatchPairing.from(payload: ["other": 1]) == nil)
  }

  @Test func decodesQuestionWithRecommendedFirst() throws {
    let json = """
      {"kind":"question","requestID":"r","sessionID":"s","title":"Escolher banco do cache","project":"core",
       "since":1793111820000,"questions":[{"id":"q1","text":"Qual banco usar?","multiple":false,"allowText":true,
       "options":[{"id":"pg","label":"Postgres"},{"id":"sqlite","label":"SQLite","recommended":true},
       {"id":"redis","label":"Redis"}]}]}
      """
    let request = try JSONDecoder().decode(WatchRequest.self, from: Data(json.utf8))
    guard case .question(let question) = request else { Issue.record("not a question"); return }
    #expect(question.questions[0].orderedOptions.map(\.id) == ["sqlite", "pg", "redis"])
    #expect(request.answerableOnWatch)
    #expect(request.project == "core")
  }

  @Test func unsupportedFormIsNotAnswerable() throws {
    let json = #"{"kind":"question","requestID":"r","sessionID":"s","title":"t","project":"p","since":1,"questions":[]}"#
    #expect(!(try JSONDecoder().decode(WatchRequest.self, from: Data(json.utf8))).answerableOnWatch)
  }

  @Test func decodesPermission() throws {
    let json = """
      {"kind":"permission","requestID":"r2","sessionID":"s","title":"Rodar testes","project":"core","since":1,
       "action":"bash","resources":["bun test"],"summary":"bash · bun test --filter oauth"}
      """
    guard case .permission(let permission) = try JSONDecoder().decode(WatchRequest.self, from: Data(json.utf8)) else {
      Issue.record("not a permission"); return
    }
    #expect(permission.summary == "bash · bun test --filter oauth")
  }

  @Test func rejectsUnknownRequestKind() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(WatchRequest.self, from: Data(#"{"kind":"other"}"#.utf8))
    }
  }

  @Test func encodesReplies() throws {
    let question = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
      WatchReply.question([.init(questionID: "q1", optionIDs: ["sqlite"])]))) as? [String: Any]
    #expect(question?["kind"] as? String == "question")
    let answers = question?["answers"] as? [[String: Any]]
    #expect(answers?.first?["optionIDs"] as? [String] == ["sqlite"])
    #expect(answers?.first?["text"] == nil)
    let permission = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WatchReply.permission(.once)))
      as? [String: String]
    #expect(permission == ["kind": "permission", "decision": "once"])
  }

  @Test func decodesVoiceEventsIgnoringUnknownTypes() throws {
    let json = """
      {"events":[{"seq":1,"at":1,"type":"status","status":"live"},
       {"seq":2,"at":2,"type":"caption","role":"user","text":"abre um PR","final":false},
       {"seq":3,"at":3,"type":"master","state":"running","text":"Pedindo à sessão Live Activity"},
       {"seq":4,"at":4,"type":"something-new"},
       {"seq":5,"at":5,"type":"error","code":"x","message":"Falhou"}],"next":5,"ended":false}
      """
    let batch = try JSONDecoder().decode(WatchVoiceEvents.self, from: Data(json.utf8))
    #expect(batch.events.count == 5)
    #expect(batch.events[3].kind == .unknown("something-new"))
  }
}

// MARK: Presentation

@Suite struct WatchPresentationTests {
  private var state: AgentsState {
    get throws { try #require(JSONDecoder().decode(WatchStateSnapshot.self, from: Data(stateJSON.utf8)).state) }
  }

  @Test func ringArcsAreProportional() {
    let ring = WatchRing(counts: .init(working: 3, question: 0, permission: 0, failed: 0, idle: 2))
    #expect(ring.arcs.map(\.role) == [.success, .border])
    #expect(ring.arcs.map(\.start) == [0, 0.6])
    #expect(ring.arcs.map { ($0.end * 100).rounded() / 100 } == [0.6, 1])
    #expect(!ring.idle)
  }

  @Test func ringOrderCoversEveryKindThatNeedsAlexandre() {
    let ring = WatchRing(counts: .init(working: 1, question: 1, permission: 1, failed: 1, idle: 0, unread: 1))
    #expect(ring.arcs.map(\.role) == [.accent, .warning, .error, .primary])
    #expect(ring.arcs.last?.end == 1 && ring.number == 4)
  }

  @Test func emptyRingIsGray() {
    #expect(WatchRing(counts: .init(working: 0, question: 0, permission: 0, failed: 0, idle: 0)).idle)
    #expect(WatchRing(counts: nil).arcs == [.init(role: .border, start: 0, end: 1)])
  }

  @Test func needsComeFirstThenTheCollapsedWork() throws {
    let state = try self.state
    #expect(state.dashboardRows().map(\.id) == ["attention-question-s2", "attention-permission-s3", "working"])
    #expect(state.dashboardRows(working: true).map(\.id) == [
      "attention-question-s2", "attention-permission-s3", "working", "session-s1", "session-s4",
    ])
  }

  @Test func requestWithoutItsAttentionItemStaysAsANeed() throws {
    var state = try self.state
    state.attention = [state.attention[0]]
    #expect(state.dashboardRows().map(\.id) == ["attention-question-s2", "need-permission-s3", "working"])
  }

  @Test func unreadAndFailedNeedsKeepTheirTime() throws {
    var state = try self.state
    state.counts = .init(working: 2, question: 1, permission: 0, failed: 1, idle: 0, unread: 2)
    state.needs = [
      .init(sessionID: "s2", title: "Escolher banco do cache", project: "core", directory: "/r/core", kind: .question,
        since: 1_793_111_820_000),
      .init(sessionID: "s5", title: "QA Reaberto", project: "qa", directory: "/r/qa", kind: .unread,
        since: 1_793_111_000_000),
    ]
    let rows = state.dashboardRows()
    #expect(rows.map(\.id) == ["attention-question-s2", "need-unread-s5", "working"])
    guard case .need(let need) = rows[1] else { Issue.record("not a need"); return }
    #expect(need.kind.label == "respondeu" && need.date == Date(timeIntervalSince1970: 1_793_111_000))
    #expect(state.complicationLine == "4 para você")
    #expect(state.complicationDetail == "1 pergunta · 1 com erro · 2 não lidas · 2 trabalhando")
  }

  @Test func labelsUseSingularAndPlural() throws {
    var state = try self.state
    state.counts = .init(working: 1, question: 1, permission: 0, failed: 0, idle: 0, unread: 0)
    #expect(state.complicationLine == "1 para você" && state.complicationDetail == "1 pergunta · 1 trabalhando")
    state.counts.question = 0
    state.attention = []
    state.sessions = state.sessions.filter { $0.status == .working }
    #expect(state.complicationLine == "1 trabalhando · nada para você" && state.complicationDetail == nil)
    #expect(state.dashboardRows().map(\.id) == ["working"])
  }

  @Test func captionsMergeOpenLinesAndKeepTwo() {
    var captions = WatchCaptions()
    captions.apply(role: .user, text: "abre", final: false)
    captions.apply(role: .user, text: "abre um PR", final: true)
    captions.apply(role: .assistant, text: "certo", final: false)
    captions.apply(role: .assistant, text: "certo, vou pedir", final: false)
    #expect(captions.lines.map(\.text) == ["abre um PR", "certo, vou pedir"])
    captions.apply(role: .user, text: "obrigado", final: true)
    #expect(captions.lines.map(\.text) == ["certo, vou pedir", "obrigado"])
  }

  @Test func timelineSkipsRepeatedEventsAndEnds() throws {
    func batch(_ json: String) throws -> WatchVoiceEvents {
      try JSONDecoder().decode(WatchVoiceEvents.self, from: Data(json.utf8))
    }
    var timeline = WatchVoiceTimeline()
    timeline.apply(try batch(#"{"events":[{"seq":1,"at":1,"type":"caption","role":"user","text":"oi","final":true}],"next":1,"ended":false}"#))
    timeline.apply(try batch(#"{"events":[{"seq":1,"at":1,"type":"caption","role":"user","text":"oi","final":true},{"seq":2,"at":2,"type":"master","state":"running","text":"Trabalhando"}],"next":2,"ended":false}"#))
    #expect(timeline.captions.lines.count == 1)
    #expect(timeline.master?.text == "Trabalhando")
    #expect(timeline.next == 2)
    timeline.apply(try batch(#"{"events":[{"seq":3,"at":3,"type":"status","status":"ended","reason":"heartbeat"}],"next":3,"ended":true}"#))
    #expect(timeline.ended == "heartbeat")
  }
}

// MARK: Gateway client against a local HTTP server

@Suite(.serialized) struct WatchGatewayTests {
  private func client(_ server: FakeGateway) -> WatchGatewayClient {
    WatchGatewayClient(pairing: WatchPairing(deviceID: "w1", deviceToken: "device-token",
      gatewayURL: URL(string: "http://127.0.0.1:\(server.port)")!,
      access: .init(clientId: "cf-id", clientSecret: "cf-secret"), voice: .init(voiceID: "rio")), version: "0.1.0")
  }

  @Test func sendsAuthenticationHeadersAndDecodesState() async throws {
    let server = try await FakeGateway { _ in (200, "application/json", stateJSON) }
    defer { server.stop() }
    let snapshot = try await client(server).state()
    #expect(snapshot.state?.activeTotal == 4)
    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/watch/v1/state")
    #expect(request.headers["authorization"] == "Bearer device-token")
    #expect(request.headers["cf-access-client-id"] == "cf-id")
    #expect(request.headers["cf-access-client-secret"] == "cf-secret")
    #expect(request.headers["user-agent"] == "OpenCodeWatch/0.1.0")
    #expect(request.headers["x-watch-client"] == "app")
  }

  @Test func namesTheReaderForTheServerCounters() async throws {
    let server = try await FakeGateway { _ in (200, "application/json", stateJSON) }
    defer { server.stop() }
    let widget = WatchGatewayClient(pairing: client(server).pairing, version: "0.1.0", reader: .widget)
    _ = try await widget.state()
    let background = WatchGatewayClient(pairing: client(server).pairing, version: "0.1.0", reader: .background)
    _ = try await background.state(timeout: WatchBackgroundRefresh.timeout)
    #expect(server.requests.map { $0.headers["x-watch-client"] } == ["widget", "background"])
  }

  @Test func postsReplyBody() async throws {
    let server = try await FakeGateway { _ in (200, "application/json", #"{"ok":true}"#) }
    defer { server.stop() }
    try await client(server).reply("req/1", .permission(.always))
    let request = try #require(server.requests.first)
    #expect(request.method == "POST")
    #expect(request.path == "/watch/v1/requests/req%2F1/reply")
    #expect(request.headers["content-type"] == "application/json")
    let body = try JSONSerialization.jsonObject(with: request.body) as? [String: String]
    #expect(body == ["kind": "permission", "decision": "always"])
  }

  @Test func longPollCarriesCursor() async throws {
    let server = try await FakeGateway { _ in (200, "application/json", #"{"events":[],"next":7,"ended":false}"#) }
    defer { server.stop() }
    let batch = try await client(server).events("call1", after: 6)
    #expect(batch.next == 7)
    #expect(server.requests.first?.path == "/watch/v1/voice/calls/call1/events?after=6")
  }

  @Test func classifiesFailures() async throws {
    let cases: [(Int, String, String, WatchGatewayError)] = [
      (401, "application/json", #"{"error":{"code":"unauthorized","message":"x"}}"#, .unauthorized),
      (404, "application/json", #"{"error":{"code":"not_found","message":"x"}}"#, .gone),
      (409, "application/json", #"{"error":{"code":"answered","message":"x"}}"#, .gone),
      (429, "application/json", #"{"error":{"code":"rate_limited","message":"x"}}"#, .rateLimited),
      (502, "text/html", "<html>Bad gateway</html>", .unreachable),
      (403, "text/html", "error code: 1010", .unreachable),
      (500, "application/json", #"{"error":{"code":"boom","message":"Falhou no Mac"}}"#,
        .server(status: 500, code: "boom", message: "Falhou no Mac")),
    ]
    for (status, type, body, expected) in cases {
      let server = try await FakeGateway { _ in (status, type, body) }
      defer { server.stop() }
      await #expect(throws: expected) { _ = try await client(server).state() }
    }
  }

  @Test func htmlWithSuccessStatusIsUnreachable() async throws {
    let server = try await FakeGateway { _ in (200, "text/html", "<html>login</html>") }
    defer { server.stop() }
    await #expect(throws: WatchGatewayError.unreachable) { _ = try await client(server).ping() }
  }

  @Test func refusedConnectionIsUnreachable() async throws {
    let server = try await FakeGateway { _ in (200, "application/json", "{}") }
    let port = server.port
    server.stop()
    let client = WatchGatewayClient(pairing: WatchPairing(deviceID: "w", deviceToken: "t",
      gatewayURL: URL(string: "http://127.0.0.1:\(port)")!, access: .init(clientId: "a", clientSecret: "b"),
      voice: .init(voiceID: "rio")))
    await #expect(throws: WatchGatewayError.unreachable) { _ = try await client.ping() }
  }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 (one request per connection, `Connection: close`).
final class FakeGateway: @unchecked Sendable {
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  typealias Handler = @Sendable (Request) -> (Int, String, String)

  private let listener: NWListener
  private let queue = DispatchQueue(label: "fake-gateway")
  private let lock = NSLock()
  private var recorded: [Request] = []
  private let handler: Handler
  private(set) var port: UInt16 = 0

  var requests: [Request] { lock.withLock { recorded } }

  init(handler: @escaping Handler) async throws {
    self.handler = handler
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    port = try await withCheckedThrowingContinuation { continuation in
      let once = OnceFlag()
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready: if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
        case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, buffer: Data())
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let request = Self.parse(buffer) {
        self.lock.withLock { self.recorded.append(request) }
        let (status, type, body) = self.handler(request)
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
      } else if complete || error != nil {
        connection.cancel()
      } else {
        self.read(connection, buffer: buffer)
      }
    }
  }

  private static func parse(_ data: Data) -> Request? {
    guard let split = data.range(of: Data("\r\n\r\n".utf8)),
      let head = String(data: data[..<split.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = head.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let body = data[split.upperBound...]
    guard body.count >= Int(headers["content-length"] ?? "0") ?? 0 else { return nil }
    return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))
  }
}

private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false
  func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

// MARK: State sync, background refresh and age

@Suite struct WatchSyncTests {
  private final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WatchStateCache.Entry?
    var entry: WatchStateCache.Entry? {
      get { lock.withLock { value } }
      set { lock.withLock { value = newValue } }
    }
  }

  private func snapshot(_ mutate: (inout AgentsState) -> Void = { _ in }) throws -> WatchStateSnapshot {
    var snapshot = try JSONDecoder().decode(WatchStateSnapshot.self, from: Data(stateJSON.utf8))
    if var state = snapshot.state {
      mutate(&state)
      snapshot.state = state
    }
    return snapshot
  }

  private func sync(_ store: Store, _ answer: @escaping @Sendable () throws -> WatchStateSnapshot) -> WatchStateSync {
    WatchStateSync(read: { store.entry }, write: { store.entry = $0 }, fetch: { try answer() })
  }

  @Test func redrawsOnlyWhenWhatTheComplicationDrawsChanges() async throws {
    let store = Store()
    let first = try snapshot()
    let now = Date(timeIntervalSince1970: 1_793_112_000)
    guard case .fetched(let entry, true, true) = await sync(store, { first }).run(now: now) else {
      Issue.record("first fetch must redraw"); return
    }
    #expect(store.entry == entry)
    #expect(entry.fetched == now)
    // A newer `updatedAt`, other rows and titles: the ring and the totals are the same.
    let later = try snapshot { state in
      state.updatedAt += 60_000
      state.sessions.removeLast()
      state.attention[0].title = "Outro título"
    }
    guard case .fetched(_, true, false) = await sync(store, { later }).run(now: now + 60) else {
      Issue.record("same drawing must not redraw"); return
    }
    #expect(store.entry?.fetched == now + 60)
    // A session that finishes unread moves the ring.
    let unread = try snapshot { state in
      state.counts.working = 1
      state.counts.unread = 1
    }
    guard case .fetched(_, true, true) = await sync(store, { unread }).run(now: now + 120) else {
      Issue.record("other counts must redraw"); return
    }
    // The very same snapshot: nothing changed at all.
    guard case .fetched(_, false, false) = await sync(store, { unread }).run(now: now + 180) else {
      Issue.record("same snapshot is unchanged"); return
    }
  }

  @Test func failuresKeepTheCache() async throws {
    let store = Store()
    let cached = WatchStateCache.Entry(snapshot: try snapshot(), fetched: Date(timeIntervalSince1970: 1_793_112_000))
    store.entry = cached
    #expect(await sync(store, { throw WatchGatewayError.unreachable }).run() == .unreachable(cached: cached))
    #expect(await sync(store, { throw WatchGatewayError.unauthorized }).run() == .unauthorized)
    #expect(store.entry == cached)
  }

  @Test func backgroundRefreshEveryThirtyMinutesWithinAFewSeconds() {
    let now = Date(timeIntervalSince1970: 1_793_112_000)
    #expect(WatchBackgroundRefresh.next(after: now) == now + 30 * 60)
    #expect((15 * 60...30 * 60).contains(WatchBackgroundRefresh.interval))
    #expect(WatchBackgroundRefresh.next(after: now, interval: 60) == now + 60)
    #expect(WatchBackgroundRefresh.timeout < 10)
  }

  @Test func ageReadsAgoraForAMinuteThenTheRelativeText() {
    let fetched = Date(timeIntervalSince1970: 1_793_112_000)
    #expect(WatchAge.isFresh(fetched, at: fetched + 59))
    #expect(!WatchAge.isFresh(fetched, at: fetched + 60))
    #expect(WatchAge.entryDates(fetched: fetched, now: fetched + 10) == [fetched + 10, fetched + 60])
    #expect(WatchAge.entryDates(fetched: fetched, now: fetched + 240) == [fetched + 240])
    #expect(WatchAge.entryDates(fetched: nil, now: fetched) == [fetched])
    #expect(AgentsText.ago(since: fetched).format(fetched + 240) == "há 4 min.")
  }
}

// MARK: Widget push token

@Suite struct WatchWidgetTokenTests {
  final class Fake: @unchecked Sendable {
    let lock = NSLock()
    var record: WatchWidgetToken.Record?
    var sent: [(String, String, PushEnvironment)] = []
    var fail = false
    var sync: WatchWidgetToken {
      WatchWidgetToken(
        load: { self.lock.withLock { self.record } },
        save: { record in self.lock.withLock { self.record = record } },
        send: { pairing, record in
          try self.lock.withLock {
            if self.fail { throw URLError(.notConnectedToInternet) }
            self.sent.append((pairing.deviceID, record.token, record.environment))
          }
        })
    }
  }

  func pairing(_ id: String) -> WatchPairing {
    WatchPairing(deviceID: id, deviceToken: "t", gatewayURL: URL(string: "https://gateway.invalid")!,
      access: .init(clientId: "c", clientSecret: "s"), voice: .init(voiceID: "rio"))
  }

  @Test func savesBeforePairingAndSendsOnceWhenPaired() async {
    let fake = Fake()
    let token = Data([0x0a, 0xff])
    // Extension, before any pairing: kept for later.
    #expect(await fake.sync.sync(token: token, environment: .production, pairing: nil) == .pending)
    #expect(fake.record == .init(token: "0aff", environment: .production, sentTo: nil))
    // App, after pairing, without a token of its own: sends the saved one.
    #expect(await fake.sync.sync(token: nil, environment: .production, pairing: pairing("w1")) == .sent)
    #expect(fake.sent.map(\.0) == ["w1"] && fake.sent.map(\.1) == ["0aff"])
    #expect(await fake.sync.sync(token: token, environment: .production, pairing: pairing("w1")) == .upToDate)
    #expect(fake.sent.count == 1)
  }

  @Test func failureStaysPendingAndRetries() async {
    let fake = Fake()
    fake.fail = true
    #expect(await fake.sync.sync(token: Data([1]), environment: .sandbox, pairing: pairing("w1")) == .pending)
    #expect(fake.record?.sentTo == nil)
    fake.fail = false
    #expect(await fake.sync.sync(token: nil, environment: .sandbox, pairing: pairing("w1")) == .sent)
    #expect(fake.sent.first?.2 == .sandbox)
  }

  @Test func newTokenEnvironmentOrPairingSendsAgain() async {
    let fake = Fake()
    _ = await fake.sync.sync(token: Data([1]), environment: .sandbox, pairing: pairing("w1"))
    _ = await fake.sync.sync(token: Data([2]), environment: .sandbox, pairing: pairing("w1"))
    _ = await fake.sync.sync(token: Data([2]), environment: .production, pairing: pairing("w1"))
    _ = await fake.sync.sync(token: nil, environment: .production, pairing: pairing("w2"))
    #expect(fake.sent.map { "\($0.0) \($0.1) \($0.2)" } ==
      ["w1 01 sandbox", "w1 02 sandbox", "w1 02 production", "w2 02 production"])
    #expect(await fake.sync.sync(token: nil, environment: .production, pairing: nil) == .pending)
    #expect(await Fake().sync.sync(token: nil, environment: .production, pairing: pairing("w1")) == .noToken)
  }
}
