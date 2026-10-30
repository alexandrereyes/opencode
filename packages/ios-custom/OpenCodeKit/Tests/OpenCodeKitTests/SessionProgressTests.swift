import Foundation
import Testing

@testable import OpenCodeKit

/// Progresso: the same cases as the plugin's `test/progress.test.ts`, both copying upstream's web rules.
@Suite struct SessionProgressTests {
  static let plan: [JSONValue] = [
    ["content": "Ler o rastreador da Live Activity", "status": "completed"],
    ["content": "Somar o progresso do plano no plugin", "status": "completed"],
    ["content": "Adicionar a unidade todos ao contrato", "status": "completed"],
    ["content": "Atualizar a Live Activity e o relógio", "status": "in_progress"],
    ["content": "Rodar os testes do OpenCodeKit", "status": "pending"],
    ["content": "Capturar as telas no iPhone 14", "status": "pending"],
    ["content": "Migrar as fixtures antigas", "status": "cancelled"],
  ].map(Self.json)

  static func json(_ value: [String: String]) -> JSONValue { .object(value.mapValues { .string($0) }) }

  static func message(_ id: String, _ todos: [JSONValue], status: String = "completed", type: String = "assistant")
    -> ConversationMessage
  {
    var message = ConversationMessage(id: id, type: type, time: .init(created: 1))
    guard type == "assistant" else { return message }
    message.content = [
      ConversationPart(type: "text", text: "Vou atualizar o plano."),
      ConversationPart(
        type: "tool", id: "call_\(id)", name: "todowrite",
        state: .object(["status": .string(status), "input": .object(["todos": .array(todos)])])),
    ]
    return message
  }

  @Test func parseKeepsItemsWithContentAndReadsUnknownStatusAsPending() {
    let items = SessionProgress.parse(
      .array([
        Self.json(["content": "Ler", "status": "completed"]), Self.json(["content": "", "status": "pending"]),
        Self.json(["status": "pending"]), Self.json(["content": "Testar", "status": "blocked"]),
        .string("texto"), Self.json(["content": "Revisar"]),
      ]))
    #expect(
      items == [
        .init(content: "Ler", status: .completed), .init(content: "Testar", status: .pending),
        .init(content: "Revisar", status: .pending),
      ])
    #expect(SessionProgress.parse(nil).isEmpty)
  }

  @Test func numberCountsCompletedRingCountsCancelledToo() {
    let progress = SessionProgress(items: SessionProgress.parse(.array(Self.plan)))
    #expect(progress.done == 3)
    #expect(progress.finished == 4)
    #expect(progress.total == 7)
    #expect(progress.count == "3/7")
    #expect(abs(progress.fraction - 4.0 / 7.0) < 0.0001)
    #expect(progress.current?.content == "Atualizar a Live Activity e o relógio")
    #expect(progress.open)
  }

  @Test func currentItemPrecedence() {
    func current(_ statuses: [SessionProgress.Status]) -> String? {
      SessionProgress(items: statuses.enumerated().map { .init(content: "\($0.offset)", status: $0.element) })
        .current?.content
    }
    #expect(current([.completed, .pending, .inProgress, .pending]) == "2")
    #expect(current([.completed, .cancelled, .pending, .pending]) == "2")
    #expect(current([.completed, .completed, .cancelled]) == "1")
    #expect(current([.cancelled, .cancelled]) == "0")
    #expect(current([]) == nil)
    #expect(!SessionProgress(items: []).open)
    #expect(!SessionProgress(items: [.init(content: "a", status: .completed), .init(content: "b", status: .cancelled)]).open)
  }

  @Test func latestCompletedCallBeforeTheRevertBoundary() {
    let older = Self.message("msg_1", [Self.json(["content": "Antes", "status": "in_progress"])])
    let prompt = Self.message("msg_2", [], type: "user")
    let newer = Self.message("msg_3", [Self.json(["content": "Depois", "status": "in_progress"])])
    let failed = Self.message("msg_4", [Self.json(["content": "Falhou", "status": "pending"])], status: "error")
    let running = Self.message("msg_5", [Self.json(["content": "Rodando", "status": "pending"])], status: "running")
    let messages = [older, prompt, newer, failed, running]
    #expect(SessionProgress.latest(in: messages)?.map(\.content) == ["Depois"])
    #expect(SessionProgress.latest(in: SessionRevert.visible(messages, boundary: "msg_2"))?.map(\.content) == ["Antes"])
    #expect(SessionProgress.latest(in: [prompt]) == nil)
    #expect(SessionProgress.latest(in: [Self.message("msg_6", [])]) == [])
  }

  @Test func experimentalTodoFollowsTheHighestDocumentThatSetsExperimental() throws {
    func configuration(_ documents: [String]) throws -> [NewSessionConfiguration] {
      try JSONDecoder().decode([NewSessionConfiguration].self, from: Data("[\(documents.joined(separator: ","))]".utf8))
    }
    let on = #"{"type":"document","info":{"experimental":{"todo":true}}}"#
    let other = #"{"type":"document","info":{"experimental":{"subagent_depth":2}}}"#
    let plain = #"{"type":"document","info":{"model":"anthropic/claude"}}"#
    let directory = #"{"type":"directory","source":"/x"}"#
    #expect(try SessionProgress.enabled(configuration([on, plain, directory])))
    #expect(try !SessionProgress.enabled(configuration([on, other])))
    #expect(try SessionProgress.enabled(configuration([other, on])))
    #expect(try !SessionProgress.enabled(configuration([plain])))
  }

  @Test func trackerFollowsATodowriteCallToItsSuccess() throws {
    func event(_ type: String, _ fields: [String: JSONValue]) throws -> ConversationEvent {
      try JSONDecoder().decode(
        ConversationEvent.self,
        from: JSONEncoder().encode(JSONValue.object(["type": .string(type), "data": .object(fields)])))
    }
    var tracker = SessionProgress.Tracker()
    let base: [String: JSONValue] = ["sessionID": .string("ses_a"), "id": .string("call_1")]
    #expect(try tracker.apply(event("session.tool.input.started", base.merging(["name": .string("todowrite")]) { $1 })) == nil)
    #expect(try tracker.apply(event("session.tool.called", base.merging(["input": .object(["todos": .array(Self.plan)])]) { $1 })) == nil)
    let result = try tracker.apply(event("session.tool.success", base))
    #expect(result?.sessionID == "ses_a")
    #expect(result?.items.count == 7)
    // Other tools and failed calls change nothing.
    let other: [String: JSONValue] = ["sessionID": .string("ses_a"), "id": .string("call_2")]
    _ = try tracker.apply(event("session.tool.input.started", other.merging(["name": .string("edit")]) { $1 }))
    _ = try tracker.apply(event("session.tool.called", other.merging(["input": .object(["todos": .array([])])]) { $1 }))
    #expect(try tracker.apply(event("session.tool.success", other)) == nil)
    let failed: [String: JSONValue] = ["sessionID": .string("ses_a"), "id": .string("call_3")]
    _ = try tracker.apply(event("session.tool.input.started", failed.merging(["name": .string("todowrite")]) { $1 }))
    _ = try tracker.apply(event("session.tool.called", failed.merging(["input": .object(["todos": .array([])])]) { $1 }))
    _ = try tracker.apply(event("session.tool.failed", failed))
    #expect(try tracker.apply(event("session.tool.success", failed)) == nil)
  }

  static func entry(_ id: String, progress: JSONValue? = nil) throws -> NavigationEntry {
    var row: [String: JSONValue] = [
      "session": .object([
        "id": .string(id), "projectID": .string("project"), "title": .string(id),
        "location": .object(["directory": .string("/repo")]),
        "time": .object(["created": .number(100), "updated": .number(100)]),
      ])
    ]
    if let progress { row["progress"] = progress }
    return try JSONDecoder().decode(NavigationEntry.self, from: JSONEncoder().encode(JSONValue.object(row)))
  }

  static let navigationProgress: JSONValue = .object([
    "done": .number(3), "finished": .number(4), "total": .number(7),
    "current": .string("Atualizar a Live Activity e o relógio"), "todos": .array(plan),
  ])

  @Test func rowShowsItsProgressOnlyWhileTheSessionItselfExecutes() throws {
    let entries = [try Self.entry("ses_plan", progress: Self.navigationProgress), try Self.entry("ses_old")]
    func rows(active: Set<String>, live: [String: SessionProgress] = [:]) -> [String: SessionRow] {
      Dictionary(
        uniqueKeysWithValues: SessionList.rows(
          entries: entries, projects: [], active: active, pins: [], notify: [], autoApprove: false, ranks: [:],
          chatRoot: nil, progress: live
        ).map { ($0.id, $0) })
    }
    #expect(rows(active: ["ses_plan"])["ses_plan"]?.progress?.count == "3/7")
    #expect(rows(active: [])["ses_plan"]?.progress == nil)
    #expect(rows(active: ["ses_old"])["ses_old"]?.progress == nil)
    // The event stream's newer list wins; a finished list shows nothing.
    let next = SessionProgress(items: SessionProgress.parse(.array(Self.plan)).map {
      .init(content: $0.content, status: $0.status == .cancelled ? .cancelled : .completed)
    })
    #expect(rows(active: ["ses_plan"], live: ["ses_plan": next])["ses_plan"]?.progress == nil)
    let moved = SessionProgress(items: [.init(content: "a", status: .completed), .init(content: "b", status: .inProgress)])
    #expect(rows(active: ["ses_old"], live: ["ses_old": moved])["ses_old"]?.progress?.count == "1/2")
  }

  @Test func navigationRowsFromOlderServersHaveNoProgress() throws {
    #expect(try Self.entry("ses_old").progress == nil)
    #expect(try Self.entry("ses_plan", progress: Self.navigationProgress).progress?.current
      == "Atualizar a Live Activity e o relógio")
  }

  // MARK: Live Activity

  @Test func liveActivityProgressFixture() throws {
    let state = try AgentsActivityTests.state("state-progress")
    #expect(state.focus?.progress == .init(done: 3, total: 7, unit: "todos", current: "Atualizar a Live Activity e o relógio"))
    // Nothing needs Alexandre but the unread answer: the attention line wins over the Progresso line.
    #expect(state.attentionLine != nil)
    #expect(state.progressLine == nil)
    var calm = state
    calm.needs = []
    calm.counts.unread = 0
    calm.sessions = calm.sessions.filter { $0.status == .working }
    #expect(calm.progressLine == AgentsProgressLine(title: "Live Activity no iOS", count: "3/7",
      current: "Atualizar a Live Activity e o relógio"))
    #expect(AgentsLayout.lockHeight(calm) == AgentsLayout.lockHeight(state))
    let row = try #require(state.sessions.first)
    #expect(state.statusLabel(row) == "Trabalhando · 3/7")
    #expect(row.compactStatus(unread: true) == "3/7 · Atualizar a Live Activity e o relógio")
    #expect(state.islandStatus(row) == "3/7")
    #expect(row.progress?.now == "Atualizar a Live Activity e o relógio")
  }

  @Test func olderBackendsAndOtherUnitsKeepTheirLabels() throws {
    let json = """
      {"v":1,"updatedAt":1,"host":"Mac","counts":{"working":1,"question":0,"permission":0,"failed":0,"idle":0,
      "unread":0},"activeTotal":1,"focus":{"sessionID":"s","title":"T","project":"p","directory":"/d","startedAt":1,
      "progress":{"done":2,"total":3,"unit":"subagents"}},"attention":[],"attentionTotal":0,"sessions":[
      {"sessionID":"s","title":"T","project":"p","directory":"/d","status":"working",
      "progress":{"done":2,"total":3,"unit":"subagents"}}],"needs":[]}
      """
    let state = try JSONDecoder().decode(AgentsState.self, from: Data(json.utf8))
    #expect(state.focus?.progress?.current == nil)
    #expect(state.progressLine == nil)
    let row = try #require(state.sessions.first)
    #expect(row.compactStatus(unread: true) == "Trabalhando · 2/3")
    #expect(state.islandStatus(row) == "Trabalhando · 2/3")
    #expect(row.progress?.now == nil)
    #expect(AgentsLayout.lockHeight(state) < AgentsLayout.lockHeight(try AgentsActivityTests.state("state-progress")))
  }
}
