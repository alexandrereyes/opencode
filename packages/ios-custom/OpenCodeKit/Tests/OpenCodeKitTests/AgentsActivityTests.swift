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

  @Test func footerCountsAndPlurals() throws {
    func text(_ state: AgentsState) -> String { state.footer.map { "\($0.count) \($0.label)" }.joined(separator: " · ") }
    #expect(try text(Self.state("state-one-question")) == "3 trabalhando · 1 pergunta · 3 ociosas")
    #expect(try text(Self.state("state-mixed"))
      == "1 trabalhando · 1 pergunta · 1 permissão · 2 com erro · 1 ociosa")
    #expect(try text(Self.state("state-failed-only")) == "1 com erro · 2 ociosas")
    var plural = try Self.state("state-mixed")
    plural.counts = AgentsState.Counts(working: 0, question: 2, permission: 3, failed: 0, idle: 0)
    #expect(text(plural) == "2 perguntas · 3 permissões")
    let roles = try Self.state("state-mixed").footer.map(\.role)
    #expect(roles == [.success, .accent, .warning, .error, .textSecondary])
  }

  @Test func pendingTitlesAndRoles() throws {
    let one = try Self.state("state-one-question")
    #expect(!one.pendingList && one.pendingTitle == "PERGUNTA PENDENTE" && one.pendingRole == .accent)
    let two = try Self.state("state-two-questions")
    #expect(two.pendingList && two.pendingTitle == "2 PERGUNTAS PENDENTES" && two.pendingRole == .accent)
    let mixed = try Self.state("state-mixed")
    #expect(mixed.pendingTitle == "2 PENDÊNCIAS" && mixed.pendingRole == .warning)
    var permission = one
    permission.attention[0].kind = .permission
    permission.counts = AgentsState.Counts(working: 3, question: 0, permission: 1, failed: 0, idle: 3)
    #expect(permission.pendingTitle == "PERMISSÃO PENDENTE" && permission.pendingRole == .warning)
    // The backend trims `attention` to fit APNs; `attentionTotal` still selects the list layout.
    var trimmed = two
    trimmed.attention.removeLast()
    #expect(trimmed.pendingList && trimmed.pendingTitle == "2 PERGUNTAS PENDENTES")
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
