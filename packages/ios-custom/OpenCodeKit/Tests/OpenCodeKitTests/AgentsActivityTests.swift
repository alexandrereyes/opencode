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
    // `needs` (rev. 2026-10-29) lists the first three of `forYou`.
    #expect((state.needs ?? []).count == min(state.forYou, 3))
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
    // Option A (29/10): what needs Alexandre, in an orange pill; the active total only when nothing does.
    #expect(try Self.state("state-one-question").compact == [AgentsSegment("4", .primary)])
    #expect(try Self.state("state-working").compact == [AgentsSegment("1", .primary)])
    var calm = try Self.state("state-working")
    calm.counts.unread = 0
    #expect(calm.compact == [AgentsSegment("2", .success)])
  }

  @Test func expandedHeader() throws {
    func text(_ name: String) throws -> String { try Self.state(name).header.map(\.text).joined() }
    #expect(try text("state-one-question") == "4 para você · 3 trabalhando")
    #expect(try text("state-two-questions") == "5 para você · 2 trabalhando")
    #expect(try text("state-mixed") == "5 para você · 1 trabalhando")
    #expect(try text("state-working") == "1 para você · 2 trabalhando")
    #expect(try text("state-failed-only") == "3 para você")
    let mixed = try Self.state("state-mixed").header
    #expect(mixed.map(\.role) == [.primary, .textSecondary])
    var calm = try Self.state("state-working")
    calm.counts.unread = 0
    #expect(calm.header.map(\.text).joined() == "2 ativas")
    calm.activeTotal = 1
    #expect(calm.header.map(\.text).joined() == "1 ativa")
  }

  @Test func countersPutAttentionFirstAndWorkLast() throws {
    func text(_ state: AgentsState) -> [String] { state.counters.map { "\($0.count) \($0.label)" } }
    #expect(try text(Self.state("state-one-question")) == ["1 pergunta", "3 não lidas", "3 trabalhando"])
    #expect(try text(Self.state("state-two-questions")) == ["2 perguntas", "3 não lidas", "2 trabalhando"])
    var plural = try Self.state("state-mixed")
    plural.counts = AgentsState.Counts(working: 0, question: 1, permission: 3, failed: 0, idle: 1, unread: 1)
    #expect(text(plural) == ["1 pergunta", "3 permissões", "1 não lida"])
    plural.counts.permission = 1
    #expect(text(plural)[1] == "1 permissão")
    let mixed = try Self.state("state-mixed").counters
    #expect(mixed.map(\.role) == [.accent, .warning, .error, .primary])
    let working = try Self.state("state-working").counters
    #expect(working.first == AgentsCounter(count: 1, label: "não lida", role: .primary, emphasized: true))
    #expect(working.last == AgentsCounter(count: 2, label: "trabalhando", role: .textSecondary, emphasized: false))
    // Nothing for Alexandre: the green work line, as before.
    var calm = try Self.state("state-working")
    calm.counts.unread = 0
    #expect(calm.counters == [AgentsCounter(count: 2, label: "trabalhando", role: .success, emphasized: true)])
  }

  @Test func countersStopAtFourDroppingTheWorkFirst() throws {
    // state-mixed has all five counts non-zero.
    let mixed = try Self.state("state-mixed")
    #expect(mixed.counts.unread ?? 0 > 0 && mixed.counts.working > 0)
    #expect(mixed.counters.map(\.label) == ["pergunta", "permissão", "com erro", "não lida"])
    #expect(mixed.counters.count == AgentsLayout.lockMaxCounters)
  }

  @Test func failedOnlyCard() throws {
    let state = try Self.state("state-failed-only")
    #expect(state.activeTotal == 0 && state.gaugeNumber == 3 && state.gaugeLabel == "para você")
    #expect(state.counters.map { "\($0.count) \($0.label)" } == ["1 com erro", "2 não lidas"])
    let arcs = state.gauge(gap: 0)
    #expect(arcs.map(\.role) == [.error, .primary] && arcs.map(\.dim) == [false, false])
    let line = try #require(state.attentionLine)
    #expect(line.title == "Deploy no Swarm" && line.kind == "erro" && line.role == .error && line.more == 2)
    #expect(line.since == Date(timeIntervalSince1970: 1_793_104_740))
  }

  @Test func gaugeDrawsOnlyWhatNeedsAlexandre() throws {
    let state = try Self.state("state-one-question")
    #expect(state.gaugeNumber == 4 && state.gaugeLabel == "para você")
    let arcs = state.gauge(gap: 0)
    // 1 question and 3 unread out of 4; the 3 working sessions draw no arc.
    #expect(arcs.map(\.role) == [.accent, .primary])
    #expect(abs(arcs[0].to - 1.0 / 4) < 1e-9 && arcs.last?.to == 1)
    let gapped = state.gauge(gap: 0.04)
    #expect(abs(gapped[0].from - 0.02) < 1e-9 && abs(gapped[0].to - (1.0 / 4 - 0.02)) < 1e-9)
    var single = try Self.state("state-working")
    single.counts.unread = 0
    #expect(single.gauge(gap: 0.04) == [AgentsGaugeArc(role: .success, dim: false, from: 0, to: 1)])
    #expect(single.gaugeNumber == 2 && single.gaugeLabel == "ativas")
    single.counts.working = 0
    #expect(single.gauge(gap: 0.04).isEmpty)
    // A tiny share never draws backwards.
    single.counts = AgentsState.Counts(working: 200, question: 0, permission: 0, failed: 0, idle: 1)
    #expect(single.gauge(gap: 0.05).count == 2 && single.gauge(gap: 0.05).allSatisfy { $0.to >= $0.from })
  }

  @Test func attentionLineShowsTheFirstNeedWithItsKind() throws {
    let one = try #require(try Self.state("state-one-question").attentionLine)
    #expect(one.title == "Escolher banco do cache" && one.role == .accent && one.kind == "pergunta")
    #expect(one.since == Date(timeIntervalSince1970: 1_793_104_680) && one.more == 3)
    #expect(try Self.state("state-two-questions").attentionLine?.more == 4)
    let unread = try #require(try Self.state("state-working").attentionLine)
    #expect(unread.title == "Revisar navegação" && unread.kind == "respondeu" && unread.role == .primary)
    // An older backend without `needs`: its requests first, then its failed rows without a time.
    var mixed = try Self.state("state-mixed")
    mixed.needs = nil
    #expect(mixed.needItems.map(\.kind) == [.question, .permission, .failed, .failed])
    #expect(mixed.needItems.last?.date == nil && mixed.attentionLine?.more == 4)
    mixed.attention[0].kind = .permission
    #expect(mixed.attentionLine?.role == .warning)
    var calm = try Self.state("state-working")
    calm.counts.unread = 0
    calm.needs = []
    #expect(calm.attentionLine == nil)
  }

  @Test func rowLabelsAndProgress() throws {
    let rows = try Self.state("state-one-question").sessions
    #expect(rows.map { $0.statusLabel(unread: false) } == ["Pergunta", "Trabalhando · 2/3", "Trabalhando", "Trabalhando"])
    #expect(rows.map { $0.statusRole(unread: false) } == [.accent, .success, .success, .success])
    let mixed = try Self.state("state-mixed").sessions
    #expect(mixed.map { $0.statusLabel(unread: true) } == ["Pergunta", "Permissão", "Erro", "Erro"])
    let failedOnly = try Self.state("state-failed-only")
    #expect(failedOnly.statusLabel(failedOnly.sessions[1]) == "Não lida")
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
      == .session(serverKey: "k", sessionID: "ses_01JZNAVIGATIONREVIEW000004", directory: "/Users/alexandremartins/Dev/opencode2"))
    var calm = try Self.state("state-working")
    calm.needs = []
    #expect(AgentsDeepLink.card(calm, serverKey: "k")
      == .session(serverKey: "k", sessionID: "ses_01JZLIVEACTIVITY0000000001",
        directory: "/Users/alexandremartins/Worktrees/opencode2-live-activity"))
    #expect(AgentsDeepLink.card(try Self.state("state-failed-only"), serverKey: "k")
      == .session(serverKey: "k", sessionID: "ses_01JZDEPLOYSWARM00000000005", directory: "/Users/alexandremartins/Dev/core-infra"))
    var idle = try Self.state("state-failed-only")
    idle.needs = []
    #expect(AgentsDeepLink.card(idle, serverKey: "k") == .sessions(serverKey: "k"))
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
    #expect(island.rows == min(state.islandRows.count, 3))
    #expect(island.more == (state.islandTotal > island.rows ? state.islandTotal - island.rows : nil))
  }

  @Test func islandShowsTwoNeedsAndCountsTheOthers() throws {
    let state = try AgentsActivityTests.state("state-one-question")
    #expect(state.islandRows.map(\.title) == ["Escolher banco do cache", "Revisar navegação"])
    #expect(state.islandRows.map { state.statusLabel($0) } == ["Pergunta", "Não lida"])
    #expect(AgentsLayout.island(state) == AgentsLayout.Island(rows: 2, more: 2, height: 74))
  }

  @Test func islandKeepsTheMoreLineOnlyWhenItFits() throws {
    var state = try AgentsActivityTests.state("state-one-question")
    // Nothing for Alexandre: the session rows, as before.
    state.counts.question = 0
    state.counts.unread = 0
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
    #expect(AgentsLayout.lockHeight(state) == (state.attentionLine == nil ? 121 : 150))
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
    // `needs` carries a time for failures too; the fourth row is past its three items.
    #expect(mixed.asked(mixed.sessions[2]) == Date(timeIntervalSince1970: 1_793_104_740))
    #expect(mixed.asked(mixed.sessions[3]) == nil)
    let working = try AgentsActivityTests.state("state-working")
    #expect(working.watchRows.map(\.title) == ["Revisar navegação", "Live Activity no iOS"])
  }
}


/// `counts.unread` (rev. 2026-10-28): unread sessions replace "concluídas há pouco" when the backend sends it; older
/// backends keep the `idle` behaviour.
@Suite struct AgentsUnreadTests {
  private func withUnread(_ name: String, _ unread: Int) throws -> AgentsState {
    var state = try AgentsActivityTests.state(name)
    state.counts.unread = unread
    return state
  }

  /// The same fixture as an older backend sends it, without `unread`.
  private func legacy(_ name: String) throws -> AgentsState {
    var state = try AgentsActivityTests.state(name)
    state.counts.unread = nil
    return state
  }

  @Test func decodesWithAndWithoutUnread() throws {
    #expect(try AgentsActivityTests.state("state-working").counts.unread == 1)
    let legacyJSON = #"{"working":1,"question":0,"permission":0,"failed":0,"idle":4}"#
    let legacyCounts = try JSONDecoder().decode(AgentsState.Counts.self, from: Data(legacyJSON.utf8))
    #expect(legacyCounts.unread == nil && legacyCounts.finished == AgentsState.Finished(count: 4, unread: false))
    let json = #"{"working":1,"question":0,"permission":0,"failed":0,"idle":4,"unread":2}"#
    let counts = try JSONDecoder().decode(AgentsState.Counts.self, from: Data(json.utf8))
    #expect(counts.unread == 2 && counts.finished == AgentsState.Finished(count: 2, unread: true))
    let null = #"{"working":1,"question":0,"permission":0,"failed":0,"idle":4,"unread":null}"#
    #expect(try JSONDecoder().decode(AgentsState.Counts.self, from: Data(null.utf8)).finished.count == 4)
    // Encoding omits an absent `unread`, as the wire convention requires.
    let old = AgentsState.Counts(working: 1, question: 0, permission: 0, failed: 0, idle: 4)
    #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("unread"))
  }

  @Test func countersUseUnreadWithPlurals() throws {
    func text(_ state: AgentsState) -> [String] { state.counters.map { "\($0.count) \($0.label)" } }
    let one = try withUnread("state-working", 1)
    #expect(text(one) == ["1 não lida", "2 trabalhando"])
    #expect(one.counters.first == AgentsCounter(count: 1, label: "não lida", role: .primary, emphasized: true))
    #expect(text(try withUnread("state-working", 3)) == ["3 não lidas", "2 trabalhando"])
    // Zero unread hides the line even though `idle` is non-zero.
    #expect(text(try withUnread("state-working", 0)) == ["2 trabalhando"])
    // Without `unread`, the fallback is unchanged.
    #expect(text(try legacy("state-working")) == ["2 trabalhando", "1 concluída há pouco"])
    #expect(try legacy("state-working").counters.last?.role == .textSecondary)
    var plural = try legacy("state-working")
    plural.counts.idle = 3
    #expect(text(plural).last == "3 concluídas há pouco")
  }

  @Test func fiveCountsDropTheWorkFirst() throws {
    let mixed = try withUnread("state-mixed", 2)
    #expect(mixed.counters.map(\.label) == ["pergunta", "permissão", "com erro", "não lidas"])
  }

  @Test func failedOnlyWithUnread() throws {
    let state = try withUnread("state-failed-only", 2)
    #expect(state.counters.map { "\($0.count) \($0.label)" } == ["1 com erro", "2 não lidas"])
    let arcs = state.gauge(gap: 0)
    #expect(arcs.map(\.role) == [.error, .primary] && arcs.map(\.dim) == [false, false])
  }

  @Test func gaugeUsesTheOrangeArcForUnread() throws {
    let state = try withUnread("state-one-question", 3)
    #expect(state.gauge(gap: 0).map(\.role) == [.accent, .primary])
    // An older backend's recently finished sessions stay gray beside the work.
    let old = try legacy("state-working").gauge(gap: 0)
    #expect(old.map(\.role) == [.success, .textSecondary] && old.last?.dim == true)
    let failed = try legacy("state-failed-only")
    #expect(failed.counters.map(\.label) == ["com erro", "concluídas há pouco"])
  }

  @Test func idleRowsReadAsUnread() throws {
    let state = try withUnread("state-failed-only", 2)
    let idle = state.sessions[1]
    #expect(state.statusLabel(idle) == "Não lida" && state.statusRole(idle) == .primary)
    let old = try legacy("state-failed-only")
    #expect(old.statusLabel(idle) == "Concluída" && old.statusRole(idle) == .textSecondary)
    #expect(state.statusLabel(state.sessions[0]) == "Erro")
  }

  @Test func watchRingUsesOrangeForUnreadAndGrayAsFallback() {
    // Option A: only what needs Alexandre draws, and its count is the orange number.
    let unread = WatchRing(counts: .init(working: 3, question: 1, permission: 0, failed: 0, idle: 4, unread: 1))
    #expect(unread.arcs.map(\.role) == [.accent, .primary])
    #expect(unread.arcs.map(\.start) == [0, 0.5])
    #expect(unread.number == 2 && unread.numberRole == .primary)
    let old = WatchRing(counts: .init(working: 3, question: 0, permission: 0, failed: 0, idle: 1))
    #expect(old.arcs.map(\.role) == [.success, .border] && old.number == 3 && old.numberRole == .textStrong)
    let onlyUnread = WatchRing(counts: .init(working: 0, question: 0, permission: 0, failed: 0, idle: 0, unread: 2))
    #expect(onlyUnread.arcs == [.init(role: .primary, start: 0, end: 1)] && !onlyUnread.idle && onlyUnread.number == 2)
    let none = WatchRing(counts: .init(working: 0, question: 0, permission: 0, failed: 0, idle: 3, unread: 0))
    #expect(none.idle && none.number == 0)
  }
}
