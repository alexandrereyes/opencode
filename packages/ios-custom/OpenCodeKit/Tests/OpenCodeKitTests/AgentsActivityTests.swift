import Foundation
import Testing
@testable import OpenCodeKit

/// Contract v1 of `custom.live-activity`: the normative fixtures live beside the contract in
/// `packages/plugin-app-custom/docs/live-activity/` and are read from there, never copied.
@Suite struct AgentsActivityTests {
  static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../../plugin-app-custom/docs/live-activity").standardized

  static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appending(path: name + ".json")) }
  static func state(_ name: String) throws -> AgentsState {
    try JSONDecoder().decode(AgentsState.self, from: data(name))
  }

  struct Push: Decodable {
    struct APS: Decodable {
      let event: String
      let timestamp: Int
      let contentState: AgentsState
      let attributesType: String?
      let attributes: Attributes?
      let staleDate: Int?
      let dismissalDate: Int?
      enum CodingKeys: String, CodingKey {
        case event, timestamp, attributes
        case contentState = "content-state"
        case attributesType = "attributes-type"
        case staleDate = "stale-date"
        case dismissalDate = "dismissal-date"
      }
    }
    struct Attributes: Decodable {
      let serverKey: String
      let theme: [String: String]
    }
    let aps: APS
  }

  @Test(arguments: ["state-one-question", "state-two-questions", "state-mixed", "state-working", "state-failed-only"])
  func decodesEveryStateFixture(_ name: String) throws {
    let state = try Self.state(name)
    #expect(state.v == 1)
    #expect(state.updatedAt == 1_793_104_860_000)
    #expect(state.host == "MacBook Pro")
    #expect(state.activeTotal == state.counts.working + state.counts.question + state.counts.permission)
    #expect(state.attentionTotal == state.counts.question + state.counts.permission)
    #expect(state.sessions.count <= 4 && state.attention.count <= 3)
    #expect(state.sessions.allSatisfy { $0.status != .unknown })
    #expect(state.focus == nil || state.counts.working > 0)
  }

  @Test func convertsEpochMillisecondsToDates() throws {
    let state = try Self.state("state-one-question")
    #expect(state.updated == Date(timeIntervalSince1970: 1_793_104_860))
    #expect(state.focus?.started == Date(timeIntervalSince1970: 1_793_104_136))
    #expect(state.attention.first?.asked == Date(timeIntervalSince1970: 1_793_104_680))
    #expect(state.focus?.progress == AgentsState.Progress(done: 2, total: 3, unit: "subagents"))
    // Round trip keeps integers on the wire, as ActivityKit content and the backend expect.
    let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    #expect(encoded.contains("\"startedAt\":1793104136000"))
  }

  @Test(arguments: ["push-start", "push-update", "push-end"])
  func decodesPushBodies(_ name: String) throws {
    let push = try JSONDecoder().decode(Push.self, from: Self.data(name))
    #expect(push.aps.event == String(name.dropFirst(5)))
    #expect(push.aps.contentState.v == 1)
    #expect(push.aps.staleDate != nil)
    if name == "push-start" {
      #expect(push.aps.attributesType == "AgentsActivityAttributes")
      #expect(push.aps.attributes?.serverKey == "mac-principal")
      #expect(push.aps.attributes?.theme.count == 12)
    }
    if name == "push-end" {
      #expect(push.aps.dismissalDate != nil)
      #expect(push.aps.contentState.focus == nil && push.aps.contentState.activeTotal == 0)
    }
  }

  @Test func decodesAttributesThemeWithEveryRequiredRole() throws {
    let attributes = try JSONDecoder().decode(Push.Attributes.self, from: Self.data("attributes"))
    let required = ["background", "surface", "border", "textStrong", "text", "textSecondary", "textWeak", "primary",
      "success", "warning", "error", "accent"]
    #expect(Set(required).isSubset(of: attributes.theme.keys))
    for role in [ThemeRole.background, .accent, .error] {
      #expect(AgentsTheme.color(attributes.theme, role) != nil)
    }
    #expect(AgentsTheme.color(attributes.theme, .accent).map(AgentsTheme.hex) == "#9988e5ff")
  }

  @Test func snapshotSendsEveryRequiredRoleAsHex() {
    let theme = AgentsTheme.snapshot { _ in ThemeColor(css: "#12345680")! }
    #expect(theme.count <= 24)
    #expect(Set(["background", "surface", "border", "textStrong", "text", "textSecondary", "textWeak", "primary",
      "success", "warning", "error", "accent"]).isSubset(of: theme.keys))
    #expect(theme.values.allSatisfy { $0 == "#12345680" })
    #expect(theme.keys.allSatisfy { $0.count <= 32 })
  }

  @Test func acceptsNullOptionalsAndUnknownValues() throws {
    let json = """
      {"v":1,"updatedAt":1793104860000,"host":"Mac","counts":{"working":1,"question":0,"permission":0,"failed":0,
      "idle":0},"activeTotal":1,"focus":{"sessionID":"s","title":"T","project":"p","directory":"/d",
      "startedAt":1793104136000,"activity":null,"progress":{"done":1,"total":4,"unit":"tasks"}},"attention":[],
      "attentionTotal":0,"sessions":[{"sessionID":"s","title":"T","project":"p","directory":"/d",
      "status":"archived","progress":null}]}
      """
    let state = try JSONDecoder().decode(AgentsState.self, from: Data(json.utf8))
    #expect(state.focus?.activity == nil)
    #expect(state.focus?.progress?.label == "1/4")
    #expect(state.sessions.first?.status == .unknown)
    #expect(state.sessions.first?.progress == nil)
  }

  @Test func minimalPriority() throws {
    #expect(try Self.state("state-mixed").minimal == .failed(2))
    #expect(try Self.state("state-failed-only").minimal == .failed(1))
    #expect(try Self.state("state-one-question").minimal == .question(1))
    #expect(try Self.state("state-working").minimal == .mascot)
    var permission = try Self.state("state-working")
    permission.counts.permission = 2
    #expect(permission.minimal == .permission(2))
    #expect(AgentsMinimal.failed(1).role == .error && AgentsMinimal.question(1).role == .accent)
    #expect(AgentsMinimal.permission(1).symbol == "hand.raised.fill" && AgentsMinimal.mascot.role == .success)
  }

  @Test func compactTrailing() throws {
    #expect(try Self.state("state-one-question").compact
      == [AgentsSegment("1", .warning), AgentsSegment("/4", .textSecondary)])
    #expect(try Self.state("state-working").compact == [AgentsSegment("2", .success)])
  }

  @Test func expandedHeader() throws {
    func text(_ name: String) throws -> String { try Self.state(name).header.map(\.text).joined() }
    #expect(try text("state-one-question") == "4 ativas · 1 precisa de você")
    #expect(try text("state-two-questions") == "4 ativas · 2 precisam de você")
    #expect(try text("state-mixed") == "3 ativas · 2 precisam de você · 2 com erro")
    #expect(try text("state-working") == "2 ativas")
    #expect(try text("state-failed-only") == "0 ativas · 1 com erro")
    let mixed = try Self.state("state-mixed").header
    #expect(mixed[2].role == .warning && mixed[4].role == .error)
    var one = try Self.state("state-working")
    one.activeTotal = 1
    #expect(one.header.map(\.text).joined() == "1 ativa")
  }

  @Test func countersPluralsAndOrder() throws {
    func text(_ state: AgentsState) -> [String] { state.counters.map { "\($0.count) \($0.label)" } }
    #expect(try text(Self.state("state-one-question")) == ["3 trabalhando", "1 pergunta", "3 concluídas há pouco"])
    #expect(try text(Self.state("state-two-questions")) == ["2 trabalhando", "2 perguntas", "3 concluídas há pouco"])
    var plural = try Self.state("state-mixed")
    plural.counts = AgentsState.Counts(working: 0, question: 1, permission: 3, failed: 0, idle: 1)
    #expect(text(plural) == ["1 pergunta", "3 permissões", "1 concluída há pouco"])
    plural.counts.permission = 1
    #expect(text(plural)[1] == "1 permissão")
    let mixed = try Self.state("state-mixed").counters
    #expect(mixed.map(\.role) == [.success, .accent, .warning, .error])
    #expect(try Self.state("state-working").counters.last == AgentsCounter(count: 1, label: "concluída há pouco",
      role: .textSecondary, emphasized: false))
  }

  @Test func countersStopAtFourDroppingRecentlyFinishedFirst() throws {
    // state-mixed has all five counts non-zero.
    let mixed = try Self.state("state-mixed")
    #expect(mixed.counts.idle > 0)
    #expect(mixed.counters.map(\.label) == ["trabalhando", "pergunta", "permissão", "com erro"])
    #expect(mixed.counters.count == AgentsLayout.lockMaxCounters)
  }

  @Test func failedOnlyCard() throws {
    let state = try Self.state("state-failed-only")
    #expect(state.activeTotal == 0 && state.gaugeLabel == "ativas")
    #expect(state.counters.map { "\($0.count) \($0.label)" } == ["1 com erro", "2 concluídas há pouco"])
    let arcs = state.gauge(gap: 0)
    #expect(arcs.map(\.role) == [.error, .textSecondary] && arcs.map(\.dim) == [false, true])
    #expect(state.attentionLine == nil)
  }

  @Test func gaugeArcsAreProportionalInContractOrder() throws {
    let arcs = try Self.state("state-one-question").gauge(gap: 0)
    // 3 working, 1 question, 3 idle out of 7.
    #expect(arcs.map(\.role) == [.success, .accent, .textSecondary])
    #expect(abs(arcs[0].to - 3.0 / 7) < 1e-9 && abs(arcs[1].from - 3.0 / 7) < 1e-9 && abs(arcs[1].to - 4.0 / 7) < 1e-9)
    #expect(arcs.last?.to == 1)
    let gapped = try Self.state("state-one-question").gauge(gap: 0.04)
    #expect(abs(gapped[0].from - 0.02) < 1e-9 && abs(gapped[0].to - (3.0 / 7 - 0.02)) < 1e-9)
    var single = try Self.state("state-working")
    single.counts.idle = 0
    #expect(single.gauge(gap: 0.04) == [AgentsGaugeArc(role: .success, dim: false, from: 0, to: 1)])
    single.counts.working = 0
    #expect(single.gauge(gap: 0.04).isEmpty)
    // A tiny share never draws backwards.
    single.counts = AgentsState.Counts(working: 200, question: 1, permission: 0, failed: 0, idle: 0)
    #expect(single.gauge(gap: 0.05).allSatisfy { $0.to >= $0.from })
  }

  @Test func attentionLineWithMore() throws {
    let one = try Self.state("state-one-question").attentionLine
    #expect(one?.title == "Escolher banco do cache" && one?.role == .accent && one?.more == nil)
    #expect(one?.since == Date(timeIntervalSince1970: 1_793_104_680))
    #expect(try Self.state("state-two-questions").attentionLine?.more == 1)
    var mixed = try Self.state("state-mixed")
    #expect(mixed.attentionLine?.more == 1)
    // The backend trims `attention`; `attentionTotal` still counts every request.
    mixed.attention.removeLast()
    mixed.attentionTotal = 5
    #expect(mixed.attentionLine?.more == 4)
    mixed.attention[0].kind = .permission
    #expect(mixed.attentionLine?.role == .warning)
    #expect(try Self.state("state-working").attentionLine == nil)
  }

  @Test func rowLabelsAndProgress() throws {
    let rows = try Self.state("state-one-question").sessions
    #expect(rows.map(\.statusLabel) == ["Pergunta", "Trabalhando · 2/3", "Trabalhando", "Trabalhando"])
    #expect(rows.map(\.statusRole) == [.accent, .success, .success, .success])
    let mixed = try Self.state("state-mixed").sessions
    #expect(mixed.map(\.statusLabel) == ["Pergunta", "Permissão", "Erro", "Erro"])
    #expect(try Self.state("state-failed-only").sessions[1].statusLabel == "Concluída")
    #expect(try Self.state("state-working").focus?.progress?.label == "2/3 subagentes")
    #expect(AgentsState.Progress(done: 5, total: 3, unit: "subagents").fraction == 1)
  }

  @Test func agoText() throws {
    let since = try #require(try Self.state("state-one-question").attention.first?.asked)
    let style = AgentsText.ago(since: since)
    #expect(style.format(since.addingTimeInterval(180)) == "há 3 min.")
    #expect(style.format(since.addingTimeInterval(60)) == "há 1 min.")
    #expect(style.format(since.addingTimeInterval(20)) == "este minuto")
    #expect(style.format(since.addingTimeInterval(7_200)) == "há 2 h")
  }

  @Test func deepLinksRoundTripAndCardTarget() throws {
    let session = AgentsDeepLink.session(serverKey: "builtin", sessionID: "ses_1", directory: "/Users/a/Dev/x y")
    #expect(AgentsDeepLink(url: session.url) == session)
    #expect(session.url.scheme == "br.com.alexandrem.opencode")
    let list = AgentsDeepLink.sessions(serverKey: "builtin")
    #expect(AgentsDeepLink(url: list.url) == list)
    #expect(AgentsDeepLink(url: URL(string: "br.com.alexandrem.opencode://session?id=x")!) == nil)
    #expect(AgentsDeepLink(url: URL(string: "https://example.com/session?server=a&id=x")!) == nil)
    #expect(AgentsDeepLink.card(try Self.state("state-one-question"), serverKey: "k")
      == .session(serverKey: "k", sessionID: "ses_01JZCACHEDATABASE000000002", directory: "/Users/alexandremartins/Dev/opencode2"))
    #expect(AgentsDeepLink.card(try Self.state("state-working"), serverKey: "k")
      == .session(serverKey: "k", sessionID: "ses_01JZLIVEACTIVITY0000000001",
        directory: "/Users/alexandremartins/Worktrees/opencode2-live-activity"))
    #expect(AgentsDeepLink.card(try Self.state("state-failed-only"), serverKey: "k") == .sessions(serverKey: "k"))
  }

  @Test func changedEventDecodesStateOrNull() throws {
    let state = String(decoding: try Self.data("state-mixed"), as: UTF8.self)
    func event(_ payload: String) throws -> ConversationEvent {
      try JSONDecoder().decode(ConversationEvent.self, from: Data(
        #"{"type":"rpc.custom.live-activity.changed","data":\#(payload)}"#.utf8))
    }
    #expect(AgentsChange.decode(try event(#"{"state":\#(state)}"#))?.state?.counts.failed == 2)
    #expect(AgentsChange.decode(try event(#"{"state":null}"#)) == AgentsChange(state: nil))
    #expect(AgentsChange.decode(try event(#"{}"#)) == AgentsChange(state: nil))
    let other = try JSONDecoder().decode(ConversationEvent.self, from: Data(
      #"{"type":"rpc.custom.device.request","data":{}}"#.utf8))
    #expect(AgentsChange.decode(other) == nil)
  }

  @Test func registrationWireShape() throws {
    let registration = AgentsRegistration(deviceID: "D", serverKey: "builtin", environment: .sandbox,
      theme: ["accent": "#9988e5ff"], pushToStartToken: nil)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any]
    #expect(object?["environment"] as? String == "sandbox")
    #expect(object?["pushToStartToken"] == nil)
    #expect(Data([0x0a, 0xff]).hexToken == "0aff")
  }

  @Test func pushEnvironmentFromProvisioningProfile() {
    func profile(_ entitlements: String) -> Data {
      Data(("garbage<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict>"
        + entitlements + "</dict></dict></plist>trailer").utf8)
    }
    #expect(PushEnvironment.resolve(profile: nil, simulator: true) == .sandbox)
    #expect(PushEnvironment.resolve(profile: nil, simulator: false) == .production)
    #expect(PushEnvironment.resolve(profile: profile("<key>aps-environment</key><string>development</string>"),
      simulator: false) == .sandbox)
    #expect(PushEnvironment.resolve(profile: profile("<key>aps-environment</key><string>production</string>"),
      simulator: false) == .production)
    #expect(PushEnvironment.resolve(profile: profile("<key>get-task-allow</key><true/>"), simulator: false) == .sandbox)
    #expect(PushEnvironment.resolve(profile: Data("not a profile".utf8), simulator: false) == .production)
  }

  @Test func unsupportedServerIsRecognized() {
    #expect(AgentsSupport.unsupported(ClientError.rpc("rpc.method_not_found")))
    #expect(AgentsSupport.unsupported(ClientError.rpc("rpc.unavailable")))
    #expect(AgentsSupport.unsupported(ClientError.http(404)))
    #expect(!AgentsSupport.unsupported(ClientError.http(500)))
    #expect(!AgentsSupport.unsupported(URLError(.timedOut)))
  }
}

/// Fixed heights of `AgentsLayout`: the expanded island and the Lock Screen never pass their measured limits.
@Suite struct AgentsLayoutTests {
  @Test(arguments: ["state-one-question", "state-two-questions", "state-mixed", "state-working", "state-failed-only"])
  func islandFitsUnderTheCeiling(_ name: String) throws {
    let state = try AgentsActivityTests.state(name)
    let island = AgentsLayout.island(state)
    #expect(island.height <= AgentsLayout.islandCeiling)
    #expect(AgentsLayout.islandCeiling < AgentsLayout.islandRegion)
    #expect(island.rows == min(state.sessions.count, 3))
    #expect(island.more == (state.sessions.count > 3 ? state.sessions.count - 3 : nil))
  }

  @Test func islandKeepsTheMoreLineOnlyWhenItFits() throws {
    var state = try AgentsActivityTests.state("state-one-question")
    #expect(AgentsLayout.island(state) == AgentsLayout.Island(rows: 3, more: 1, height: 94))
    state.sessions = Array(state.sessions.prefix(3))
    #expect(AgentsLayout.island(state) == AgentsLayout.Island(rows: 3, more: nil, height: 82))
    state.sessions = []
    #expect(AgentsLayout.island(state) == AgentsLayout.Island(rows: 0, more: nil, height: 18))
    // Even an out-of-contract list longer than four sessions stays at three rows.
    state.sessions = Array(repeating: try AgentsActivityTests.state("state-mixed").sessions[0], count: 9)
    #expect(AgentsLayout.island(state).rows == 3 && AgentsLayout.island(state).height <= AgentsLayout.islandCeiling)
  }

  @Test(arguments: ["state-one-question", "state-two-questions", "state-mixed", "state-working", "state-failed-only"])
  func lockScreenFitsTheLimit(_ name: String) throws {
    let state = try AgentsActivityTests.state(name)
    #expect(AgentsLayout.lockHeight(state) <= AgentsLayout.lockLimit)
    #expect(AgentsLayout.lockHeight(state) == (state.attention.isEmpty ? 121 : 150))
    #expect(state.counters.count <= AgentsLayout.lockMaxCounters)
  }

  @Test func counterLinesFitBesideTheRing() {
    #expect(CGFloat(AgentsLayout.lockMaxCounters) * AgentsLayout.lockCounter <= AgentsLayout.lockRing)
  }
}

/// At most one activity per server on screen, in any state (contract Lifecycle, rev. 2026-10-27).
@Suite struct AgentsDuplicatesTests {
  typealias Candidate = AgentsDuplicates.Candidate

  @Test func keepsTheNewestLiveActivityPerServer() {
    let ended = Candidate(id: "old-ended", serverKey: "mac", alive: false, updatedAt: 300, sequence: 0)
    let local = Candidate(id: "local", serverKey: "mac", alive: true, updatedAt: 100, sequence: 1)
    let pushed = Candidate(id: "pushed", serverKey: "mac", alive: true, updatedAt: 200, sequence: 2)
    let other = Candidate(id: "other", serverKey: "sandbox", alive: true, updatedAt: 50, sequence: 3)
    // The ended "9 ociosas" card goes even though its final state is newer; the older live duplicate goes too.
    #expect(Set(AgentsDuplicates.toEnd([ended, local, pushed, other])) == ["old-ended", "local"])
  }

  @Test func tieBreaksOnTheLastSeenActivity() {
    let first = Candidate(id: "a", serverKey: "mac", alive: true, updatedAt: 100, sequence: 4)
    let second = Candidate(id: "b", serverKey: "mac", alive: true, updatedAt: 100, sequence: 7)
    #expect(AgentsDuplicates.toEnd([second, first]) == ["a"])
  }

  @Test func endedActivitiesNeverStayVisible() {
    let ended = Candidate(id: "ended", serverKey: "mac", alive: false, updatedAt: 100, sequence: 0)
    let dismissed = Candidate(id: "gone", serverKey: "mac", alive: false, updatedAt: 90, sequence: 1)
    #expect(Set(AgentsDuplicates.toEnd([ended, dismissed])) == ["ended", "gone"])
    #expect(AgentsDuplicates.toEnd([Candidate(id: "only", serverKey: "mac", alive: true, updatedAt: 1, sequence: 0)])
      .isEmpty)
    #expect(AgentsDuplicates.toEnd([]).isEmpty)
  }
}

/// The Apple Watch Smart Stack card (`.small`).
@Suite struct AgentsWatchTests {
  @Test func ringFollowsTheFocusProgress() throws {
    var state = try AgentsActivityTests.state("state-working")
    #expect(state.ring == .segments(done: 2, total: 3))
    state.focus?.progress = AgentsState.Progress(done: 3, total: 12, unit: "subagents")
    #expect(state.ring == .continuous(0.25))
    state.focus?.progress = AgentsState.Progress(done: 8, total: 8, unit: "subagents")
    #expect(state.ring == .segments(done: 8, total: 8))
    state.focus?.progress = nil
    #expect(state.ring == .full)
    #expect(try AgentsActivityTests.state("state-failed-only").ring == .track)
  }

  @Test func badgeAndRows() throws {
    let mixed = try AgentsActivityTests.state("state-mixed")
    #expect(mixed.watchBadge == .failed(2))
    #expect(try AgentsActivityTests.state("state-one-question").watchBadge == .question(1))
    #expect(try AgentsActivityTests.state("state-working").watchBadge == nil)
    #expect(mixed.watchRows.map(\.title) == ["Escolher banco do cache", "Corrigir login OAuth"])
    #expect(mixed.asked(mixed.watchRows[0]) == mixed.attention[0].asked)
    #expect(mixed.asked(mixed.watchRows[1]) == mixed.attention[1].asked)
    #expect(mixed.asked(mixed.sessions[2]) == nil)
  }
}
