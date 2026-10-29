import Foundation
import Testing

@testable import OpenCodeKit

private struct ActionRPC<T: Decodable>: Decodable { let output: T }
private func actionFixture<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Conversation"))
  return try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
private let actionModel = ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low")

@Test func modelPreferenceIntentsMatchThePluginContract() throws {
  func encoded(_ intent: PreferenceIntent) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(intent))
  }
  for favorite in [true, false] {
    #expect(
      try encoded(
        .modelFavorite(providerID: "llm-proxy", modelID: "gpt-6-luna", favorite: favorite))
        == .object([
          "type": .string("model.favorite"), "providerID": .string("llm-proxy"),
          "modelID": .string("gpt-6-luna"), "favorite": .bool(favorite),
        ]))
  }
  for visible in [true, false] {
    #expect(
      try encoded(.modelVisibility(providerID: "anthropic", modelID: "opus", visible: visible))
        == .object([
          "type": .string("model.visibility"), "providerID": .string("anthropic"),
          "modelID": .string("opus"), "visibility": .string(visible ? "show" : "hide"),
        ]))
  }
  #expect(
    try encoded(.modelDefault(actionModel))
      == .object([
        "type": .string("model.default"),
        "model": .object([
          "providerID": .string("llm-proxy"),
          "modelID": .string("gpt-6-luna"), "variant": .string("low"),
        ]),
      ]))
  #expect(
    try encoded(.modelDefault(nil)) == .object(["type": .string("model.default"), "model": .null]))
  let noVariant = try encoded(.modelDefault(ModelReference(id: "x", providerID: "y")))
  #expect(noVariant.object?["model"]?.object?["variant"] == nil)
}

@Test func modelSearchMatchesThePWACases() {
  for query in ["gpt 5", "gpt-5", "gpt5"] {
    #expect(ConversationProjection.matchesModelSearch(query, values: ["GPT-5.5"]))
  }
  #expect(
    ConversationProjection.matchesModelSearch("open ai", values: ["GPT-5.5", "gpt-5.5", "OpenAI"]))
  #expect(
    !ConversationProjection.matchesModelSearch("claude", values: ["GPT-5.5", "gpt-5.5", "OpenAI"]))
  #expect(
    ConversationProjection.matchesModelSearch(
      "gpt-6-luna-fast", values: ["Luna 6 - fast", "gpt-6-luna-fast", "Open AI"]))
  #expect(ConversationProjection.matchesModelSearch("luna6fast", values: ["Luna 6 - fast"]))
  #expect(ConversationProjection.normalizeModelSearch("  ÓPUS___５ — 中文  ") == "ópus ５ 中文")
  #expect(ConversationProjection.normalizeModelSearch("a\u{301}b") == "a b")
  #expect(ConversationProjection.matchesModelSearch("...", values: ["anything"]))
}

@Test func providerOrderUsesSavedRanksThenPopularityThenProviderNames() throws {
  let ids = ["zebra", "openai", "opencode", "anthropic", "alpha", "llm-proxy"]
  let data = ids.map {
    "{\"id\":\"model\",\"providerID\":\"\($0)\",\"name\":\"Model\",\"limit\":{\"context\":1}}"
  }.joined(separator: ",")
  let models = try JSONDecoder().decode([ModelInfo].self, from: Data("[\(data)]".utf8))
  let providers = ids.map {
    ProviderInfo(id: $0, name: $0 == "zebra" ? "A provider" : $0 == "alpha" ? "Z provider" : $0)
  }
  #expect(
    ConversationProjection.modelProviders(models, providers: providers, order: []).map(\.id) == [
      "opencode", "anthropic", "openai", "zebra", "llm-proxy", "alpha",
    ])
  #expect(
    ConversationProjection.modelProviders(
      models, providers: providers, order: ["alpha", "llm-proxy"]
    ).map(\.id) == ["alpha", "llm-proxy", "opencode", "anthropic", "openai", "zebra"])
}

@Test func explicitFavoritesOverrideLegacyFlagsWithoutChangingVisibility() throws {
  let model = try #require(actionFixture("models", DataResponse<[ModelInfo]>.self).data.first)
  let json = """
    {"user":[{"providerID":"\(model.providerID)","modelID":"\(model.id)","visibility":"hide","favorite":true}],"variant":{},"favorites":[]}
    """
  let preferences = try JSONDecoder().decode(Preferences.Models.self, from: Data(json.utf8))
  #expect(!ConversationProjection.favorite(model, preferences: preferences))
  #expect(ConversationProjection.visibleModels([model], preferences: preferences).isEmpty)
}

private actor RequestRecorder {
  var requests: [URLRequest] = []
  func record(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    let url = try #require(request.url)
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil))
    return (Data(), response)
  }
}

@Test func missingDefaultModelIsNotADecodingFailure() async throws {
  let client = OpenCodeClient(
    configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)
  ) { request in
    (
      Data("{}".utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
  #expect(try await client.defaultModel(directory: "/sandbox") == nil)
}

@Test func actionHTTPMethodsOwnersAndReplyBodies() async throws {
  let recorder = RequestRecorder()
  let client = OpenCodeClient(
    configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)
  ) { request in
    try await recorder.record(request)
  }
  let permission = try #require(
    actionFixture("permissions", DataResponse<[PermissionRequest]>.self).data.first)
  let form = try #require(actionFixture("forms", DataResponse<[PendingForm]>.self).data.first)
  try await client.reply(permission, decision: .once)
  try await client.reply(form, answer: QuestionReply(form: form, values: ["q0": .string("MIT")]))
  try await client.dismiss(form)
  try await client.interrupt("ses_root", resume: true)
  try await client.interrupt("ses_child")
  try await client.background("ses_root")
  try await client.stopShell("sh_background", directory: "/sandbox/a b")
  try await client.promoteInbox("msg_queued", sessionID: "ses_root")
  try await client.cancelInbox("msg_queued", sessionID: "ses_root")
  try await client.updateInbox("msg_steer", sessionID: "ses_root", delivery: .queue)
  let requests = await recorder.requests
  #expect(
    requests.map(\.httpMethod) == [
      "POST", "POST", "DELETE", "POST", "POST", "POST", "DELETE", "PATCH", "DELETE", "PATCH",
    ])
  #expect(requests[9].url?.path == "/api/session/ses_root/inbox/msg_steer")
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: #require(requests[9].httpBody))
      == .object(["delivery": .string("queue")]))
  #expect(
    requests[0].url?.path
      == "/api/session/\(permission.sessionID)/permission/\(permission.id)/reply")
  #expect(requests[1].url?.path == "/api/session/\(form.sessionID)/form/\(form.id)/reply")
  #expect(requests[2].url?.path == "/api/session/\(form.sessionID)/form/\(form.id)")
  #expect(requests[2].httpBody == nil)
  #expect(requests[3].url?.query == "resume=true")
  #expect(requests[4].url?.query == nil)
  #expect(
    URLComponents(url: requests[6].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
      == "/sandbox/a b")
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: #require(requests[0].httpBody))
      == .object(["decision": .string("once")]))
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: #require(requests[1].httpBody))
      == .object(["answer": .object(["q0": .string("MIT")])]))
  #expect(
    try JSONDecoder().decode(JSONValue.self, from: #require(requests[7].httpBody))
      == .object(["delivery": .string("steer")]))
}

private actor ActionRecorder: ConversationActions {
  var calls: [String] = []
  var requests: [PromptRequest] = []
  let failures: Int
  let permanent: Bool
  var currentAgent = "plan"
  init(failures: Int = 0, permanent: Bool = false) {
    self.failures = failures
    self.permanent = permanent
  }
  func session(_ id: String) throws -> Session {
    try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(JSONValue.object([
      "id": .string(id), "projectID": .string("project_test"),
      "location": .object(["directory": .string("/test")]),
      "time": .object(["created": .number(1), "updated": .number(1)]),
      "agent": .string(currentAgent),
    ])))
  }
  func selectAgent(_ agent: String, sessionID: String) {
    calls.append("agent:\(agent)")
    currentAgent = agent
  }
  func selectModel(_ model: ModelReference, sessionID: String) {
    calls.append("model:\(model.providerID)/\(model.id):\(model.variant ?? "default")")
  }
  func prompt(_ request: PromptRequest, sessionID: String) throws {
    calls.append("prompt:\(request.id)")
    requests.append(request)
    if requests.count <= failures {
      throw permanent ? ClientError.http(400) : ClientError.http(503)
    }
  }
  func cancelInbox(_ id: String, sessionID: String) { calls.append("cancel:\(id)") }
}

@Test func promptEncodingUsesStableIDAndPresentationMetadata() throws {
  let request = PromptRequest(
    id: "msg_example", text: "Uma\r\nmensagem\r🙂", delivery: .steer, agent: "build",
    model: actionModel)
  let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
  #expect(value.object?["id"] == .string("msg_example"))
  #expect(value.object?["text"] == .string("Uma\nmensagem\n🙂"))
  #expect(value.object?["delivery"] == .string("steer"))
  #expect(value.object?["metadata"]?.object?["displayText"] == value.object?["text"])
  #expect(value.object?["metadata"]?.object?["comments"] == .array([]))
  #expect(value.object?["metadata"]?.object?["model"]?.object?["modelID"] == .string("gpt-6-luna"))
  #expect(value.object?["model"] == nil)
  #expect(value.object?["agent"] == nil)
  #expect(value.object?["resume"] == nil)
  #expect(
    PromptRequest(text: "a", delivery: .queue, agent: "build", model: actionModel).id != request.id)
}

@Test func promptDeliveryMatchesIdleBusyAndAlternate() {
  for preference in [PromptDelivery.queue, .steer] {
    #expect(PromptDelivery.choose(busy: false, preference: preference) == .steer)
    #expect(PromptDelivery.choose(busy: false, preference: preference, alternate: true) == .steer)
    #expect(PromptDelivery.choose(busy: true, preference: preference) == preference)
    #expect(
      PromptDelivery.choose(busy: true, preference: preference, alternate: true) != preference)
  }
}

@Test(arguments: ["build", "mestra"])
func repeatedSubmissionsReadCurrentServerAgent(_ agent: String) async throws {
  let recorder = ActionRecorder()
  await recorder.selectAgent(agent, sessionID: "ses_test")
  for _ in 0..<3 {
    let request = PromptRequest(text: "oi", delivery: .steer, agent: agent, model: actionModel)
    try await PromptSubmission(
      request: request, sessionID: "ses_test", agent: agent, model: actionModel
    ).send(using: recorder)
  }
  #expect(await recorder.calls.filter { $0.hasPrefix("agent:") } == ["agent:\(agent)"])
  let request = PromptRequest(text: "oi", delivery: .steer, agent: "explore", model: actionModel)
  let submission = PromptSubmission(
    request: request, sessionID: "ses_test", agent: "explore", model: actionModel)
  try await submission.send(using: recorder)
  try await submission.send(using: recorder)
  #expect(await recorder.calls.filter { $0.hasPrefix("agent:") } == ["agent:\(agent)", "agent:explore"])
}

@Test(arguments: [nil, "default", "low", "high"] as [String?])
func modelSelectionKeepsServerDeduplicationAndVariant(_ variant: String?) async throws {
  let recorder = ActionRecorder()
  let model = ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: variant)
  let request = PromptRequest(text: "oi", delivery: .steer, agent: "plan", model: model)
  try await PromptSubmission(
    request: request, sessionID: "ses_test", agent: "plan", model: model
  ).send(using: recorder)
  #expect(await recorder.calls == [
    "model:llm-proxy/gpt-6-luna:\(variant ?? "default")", "prompt:\(request.id)",
  ])
}

@Test func steeringAppliesAgentThenModelThenAdmissionAndRetriesOnlyAdmission() async throws {
  let recorder = ActionRecorder(failures: 1)
  let request = PromptRequest(text: "ok", delivery: .steer, agent: "build", model: actionModel)
  try await PromptSubmission(
    request: request, sessionID: "ses_test", agent: "build", model: actionModel
  ).send(using: recorder)
  #expect(
    await recorder.calls == [
      "agent:build", "model:llm-proxy/gpt-6-luna:low", "prompt:\(request.id)",
      "prompt:\(request.id)",
    ])
  #expect(await recorder.requests == [request, request])
}

@Test func queueReplacementAdmitsBeforeCancelWithoutMutatingSelection() async throws {
  let recorder = ActionRecorder()
  let item = try #require(actionFixture("inbox-working", DataResponse<[InboxItem]>.self).data.first)
  #expect(item.queuedUser)
  let request = PromptRequest(
    text: "Nova mensagem", delivery: .queue, agent: "build", model: actionModel,
    restoring: item.payload)
  try await PromptSubmission(
    request: request, sessionID: item.sessionID, agent: "build", model: actionModel,
    replacing: item.id
  ).send(using: recorder)
  #expect(await recorder.calls == ["prompt:\(request.id)", "cancel:\(item.id)"])
  #expect(request.id != item.id)
}

@Test func failedReplacementLeavesOriginalUncancelledAndPermanentFailureDoesNotRetry() async {
  for permanent in [false, true] {
    let recorder = ActionRecorder(failures: 3, permanent: permanent)
    let request = PromptRequest(text: "ok", delivery: .queue, agent: "build", model: actionModel)
    do {
      try await PromptSubmission(
        request: request, sessionID: "ses_test", agent: "build", model: actionModel,
        replacing: "msg_original"
      ).send(using: recorder)
      Issue.record("Admission should fail")
    } catch {}
    #expect(await recorder.calls.count == (permanent ? 1 : 2))
    #expect(await !recorder.calls.contains("cancel:msg_original"))
    #expect(await recorder.requests.allSatisfy { $0 == request })
  }
}

@Test func permissionAndQuestionUseValuesAndOmitInactiveFields() throws {
  for decision in [PermissionReply.Decision.once, .always, .reject] {
    #expect(
      try JSONDecoder().decode(
        JSONValue.self, from: JSONEncoder().encode(PermissionReply(decision)))
        == .object(["decision": .string(decision.rawValue)]))
  }
  let form = try JSONDecoder().decode(
    PendingForm.self,
    from: Data(
      #"""
      {"id":"frm_test","sessionID":"ses_child","title":"Perguntas","fields":[
        {"key":"q0","type":"string","required":true,"options":[{"value":"MIT","label":"Permissiva"},{"value":"GPL","label":"Copyleft"}]},
        {"key":"q1","type":"multiselect","required":true,"options":[{"value":"a","label":"Primeira"},{"value":"b","label":"Segunda"}],"when":[{"key":"q0","op":"eq","value":"MIT"}]},
        {"key":"secret","type":"string","hidden":true},
        {"key":"q2","type":"string","when":[{"key":"q1","op":"eq","value":"b"}]},
        {"key":"q3","type":"string","when":[{"key":"q0","op":"neq","value":"MIT"}]},
        {"key":"q4","type":"string"}
      ]}
      """#.utf8))
  let reply = QuestionReply(
    form: form,
    values: [
      "q0": .string("MIT"), "q1": .array([.string("a"), .string("b")]), "secret": .string("omit"),
      "q2": .string("free"), "q3": .string("omit"), "q4": .string(""),
    ])
  #expect(
    reply.answer == [
      "q0": .string("MIT"), "q1": .array([.string("a"), .string("b")]), "q2": .string("free"),
    ])
  #expect(reply.valid(for: form))
  #expect(!QuestionReply(form: form, values: ["q0": .string("Permissiva")]).valid(for: form))
  #expect(!QuestionReply(form: form, values: ["q0": .string("MIT")]).valid(for: form))
  #expect(QuestionReply(form: form, values: [:]).answer.isEmpty)
  let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reply))
  #expect(value.object?["answer"] == .object(reply.answer))
}

@Test func capturedQuestionAcceptsFreeTextWithoutTouchingPrompt() throws {
  let form = try #require(actionFixture("forms", DataResponse<[PendingForm]>.self).data.first)
  let reply = QuestionReply(form: form, values: ["q0": .string("Uma resposta livre")])
  #expect(reply.valid(for: form))
  #expect(reply.answer["q0"] == .string("Uma resposta livre"))
  let prompt = PromptRequest(
    text: "Texto separado", delivery: .queue, agent: "build", model: actionModel)
  #expect(prompt.metadata["answer"] == nil)
}

@Test func pendingPermissionAndQuestionStopToolElapsedLabels() throws {
  let permissions = try actionFixture("permissions", DataResponse<[PermissionRequest]>.self).data
  let forms = try actionFixture("forms", DataResponse<[PendingForm]>.self).data
  let permissionTools = try actionFixture("transcript-permission", ActionRPC<ConversationPage>.self)
    .output.data.flatMap(\.tools)
  let questionTools = try actionFixture("transcript-question", ActionRPC<ConversationPage>.self)
    .output.data.flatMap(\.tools)
  let permission = try #require(permissionTools.first { $0.id == permissions.first?.source?.id })
  #expect(
    ConversationProjection.pendingTool(permission, permissions: permissions, forms: forms)
      == "Aguardando permissão · git push origin neon-mountain")
  let question = try #require(questionTools.first { $0.name == "question" })
  #expect(
    ConversationProjection.pendingTool(question, permissions: permissions, forms: forms)
      == "Aguardando resposta · Licença")
  #expect(ConversationProjection.pendingTool(permission, permissions: [], forms: []) == nil)
}

@Test func contextDetailMathRetainsMeasuredModelAndFamilyCost() throws {
  let messages = try actionFixture("transcript-working", ActionRPC<ConversationPage>.self).output
    .data.reversed().map { $0 }
  let models = try actionFixture("models", DataResponse<[ModelInfo]>.self).data
  let session = try actionFixture("session-working", DataResponse<Session>.self).data
  let family = try actionFixture("family-working", ActionRPC<FamilySnapshot>.self).output
  let details = ContextDetails(messages: messages, models: models, session: session, family: family)
  #expect(details.total == 441_000)
  #expect(details.model?.limit.context == 1_050_000)
  #expect(abs(try #require(details.fraction) - 0.42) < 0.0001)
  let tokens = try #require(details.tokens)
  #expect(
    details.cacheHit == tokens.cache.read / (tokens.input + tokens.cache.read + tokens.cache.write))
  #expect(details.totalCost == (session.cost ?? 0) + (family.cost ?? 0))
  #expect(
    ContextDetails(messages: [], models: models, session: session, family: family).fraction == nil)
}

@Test func workListSharesCounterRulesAndLinksOnlyRealChildren() throws {
  let messages = try actionFixture("transcript-working", ActionRPC<ConversationPage>.self).output
    .data
  let children = try actionFixture("family-page", ActionRPC<FamilyPage>.self).output.data
  let active = Set(try actionFixture("active", DataResponse<[String: ActiveState]>.self).data.keys)
  let shells = try actionFixture("shells", DataResponse<[ShellInfo]>.self).data
  let owner = try actionFixture("session-working", DataResponse<Session>.self).data.id
  let all = ConversationProjection.work(
    ownerID: owner, viewedID: owner, messages: messages, children: children, active: active,
    shells: shells)
  let work = all.filter(\.running)
  #expect(work.count == 2)
  #expect(
    Set(work.compactMap(\.sessionID)) == Set(children.filter { active.contains($0.id) }.map(\.id)))
  #expect(work.allSatisfy { $0.shellID == nil })
  // Finished direct children stay in the same list with their own state.
  #expect(Set(all.compactMap(\.sessionID)) == Set(children.filter { $0.parentID == owner }.map(\.id)))
  #expect(all.map(\.live) == all.map(\.live).sorted { $0 && !$1 })
  #expect(
    ConversationProjection.work(
      ownerID: owner, viewedID: work[0].id, messages: messages, children: children, active: active,
      shells: shells
    ).filter(\.running).count == 1)
  let noTools = ConversationProjection.work(
    ownerID: owner, viewedID: owner, messages: [], children: children, active: active,
    shells: shells)
  #expect(noTools.contains { $0.shellID != nil })
}

@Test func workStatesFollowActivityThenOutcomeAndOrderByStartNewestFirst() throws {
  func child(_ id: String, created: Double, outcome: String?) throws -> Session {
    try JSONDecoder().decode(Session.self, from: Data("""
      {"id":"\(id)","parentID":"ses_owner","projectID":"global","title":"\(id)","agent":"explore",
       "location":{"directory":"/repo"},\(outcome.map { #""outcome":"\#($0)","# } ?? "")
       "time":{"created":\(created),"updated":\(created + 90_000),"idle":\(created + 60_000)}}
      """.utf8))
  }
  let children = [
    try child("ses_done", created: 1_000, outcome: "succeeded"),
    try child("ses_failed", created: 4_000, outcome: "failed"),
    try child("ses_running", created: 2_000, outcome: "succeeded"),
    try child("ses_stopped", created: 3_000, outcome: "interrupted"),
    try child("ses_unknown", created: 500, outcome: nil),
  ]
  let work = ConversationProjection.work(
    ownerID: "ses_owner", viewedID: "ses_owner", messages: [], children: children, active: ["ses_running"],
    shells: [])
  // Running first, then finished by the last time they ran (idle), newest first.
  #expect(work.map(\.id) == ["ses_running", "ses_failed", "ses_stopped", "ses_done", "ses_unknown"])
  #expect(work.map(\.state) == [.running, .failed, .interrupted, .completed, .ended])
  #expect(work.first { $0.id == "ses_done" }?.duration == 60_000)
  #expect(work.first { $0.id == "ses_running" }?.duration == nil)
  #expect(work.map(\.state.label) == ["Em execução", "Erro", "Interrompido", "Concluído", "Encerrado"])
}

@Test func catalogPreferencesUseProviderPairVisibilityAndFavorites() throws {
  let models = try actionFixture("models", DataResponse<[ModelInfo]>.self).data
  let preferences = try actionFixture("preferences", ActionRPC<Preferences>.self).output
  #expect(preferences.data.settings.followUpBehavior == .steer)
  #expect(
    ConversationProjection.visibleModels(models, preferences: preferences.data.models).isEmpty)
  let model = try #require(models.first)
  let luna = try #require(models.first { $0.id == "gpt-6-luna" && $0.providerID == "llm-proxy" })
  #expect(ConversationProjection.matchesModel(luna, query: "gpt6luna"))
  #expect(ConversationProjection.matchesModel(luna, query: "LUNA 6"))
  #expect(ConversationProjection.matchesModel(luna, query: "llm proxy"))
  #expect(!ConversationProjection.matchesModel(luna, query: "not a model"))
  let data = """
    {"user":[{"providerID":"\(model.providerID)","modelID":"\(model.id)","visibility":"hide"}],"variant":{},"favorites":[{"providerID":"\(model.providerID)","modelID":"\(model.id)"}]}
    """
  let settings = try JSONDecoder().decode(Preferences.Models.self, from: Data(data.utf8))
  #expect(
    !ConversationProjection.visibleModels(models, preferences: settings).contains {
      $0.identity == model.identity
    })
  #expect(ConversationProjection.favorite(model, preferences: settings))
  let visible = try JSONDecoder().decode(
    Preferences.Models.self,
    from: Data(data.replacingOccurrences(of: "\"hide\"", with: "\"show\"").utf8))
  #expect(
    ConversationProjection.visibleModels(models, preferences: visible).contains {
      $0.identity == model.identity
    } == (model.enabled != false))
}

/// Production case: a reloaded running `subagent` part has `metadata: {}` (its child ID only travels in
/// ephemeral progress), so it listed beside its own active child and opened the root.
@Test func reloadedRunningSubagentCallMergesIntoItsChildAndNeverOpensTheOwner() throws {
  func call(_ id: String, status: String, ran: Double, agent: String = "opushigh", extra: String = "",
    metadata: String = "{}") -> String {
    let result = status == "completed" ? #","content":[{"type":"text","text":"ok"}]"# : ""
    return """
      {"type":"tool","id":"\(id)","name":"subagent","time":{"created":\(ran - 10),"ran":\(ran)},
       "state":{"status":"\(status)","input":{"agent":"\(agent)","description":"Corrigir alerta"\(extra)},
       "metadata":\(metadata)\(result)}}
      """
  }
  func message(_ parts: [String]) throws -> ConversationMessage {
    try JSONDecoder().decode(ConversationMessage.self, from: Data("""
      {"id":"msg_\(UUID().uuidString)","type":"assistant","agent":"build","time":{"created":1},
       "content":[\(parts.joined(separator: ","))]}
      """.utf8))
  }
  func child(_ id: String, created: Double, agent: String = "opushigh") throws -> Session {
    try JSONDecoder().decode(Session.self, from: Data("""
      {"id":"\(id)","parentID":"ses_root","projectID":"p","title":"Corrigir alerta","agent":"\(agent)",
       "location":{"directory":"/repo"},"time":{"created":\(created),"updated":\(created + 1)}}
      """.utf8))
  }
  let shell = try JSONDecoder().decode(ShellInfo.self, from: Data("""
    {"id":"sh_child","status":"running","command":"sleep 240","metadata":{"sessionID":"ses_child"},"time":{"started":5000}}
    """.utf8))
  let messages = [try message([call("toolu_live", status: "running", ran: 1_000)])]
  let children = [try child("ses_child", created: 1_033)]
  let work = ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: messages, children: children,
    active: ["ses_root", "ses_child"], shells: [shell])
  #expect(work.count == 1)
  #expect(work.first?.id == "ses_child" && work.first?.sessionID == "ses_child")
  #expect(work.first?.toolID == "toolu_live" && work.first?.state == .running)
  // Elapsed time is the call's run, not the child's own foreground shell.
  #expect(work.first?.started == 1_000)
  #expect(ConversationProjection.runningCount(
    ownerID: "ses_root", viewedID: "ses_root", messages: messages, children: children,
    active: ["ses_root", "ses_child"], shells: [shell]) == 1)

  // A continuation names its child; a new call claims only an unclaimed child of the same agent.
  let mixed = [try message([
    call("toolu_first", status: "completed", ran: 100, metadata: #"{"sessionID":"ses_old"}"#),
    call("toolu_again", status: "running", ran: 9_000, extra: #","sessionID":"ses_old""#),
    call("toolu_other", status: "running", ran: 9_100, agent: "explore"),
  ])]
  let family = [try child("ses_old", created: 110), try child("ses_new", created: 9_120, agent: "explore")]
  let links = ConversationProjection.subagentLinks(
    tools: mixed.flatMap(\.tools), children: family, ownerID: "ses_root")
  #expect(links == ["toolu_first": "ses_old", "toolu_again": "ses_old", "toolu_other": "ses_new"])
  let merged = ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: mixed, children: family,
    active: ["ses_root", "ses_old", "ses_new"], shells: [])
  #expect(Set(merged.map(\.id)) == ["ses_old", "ses_new"])
  #expect(merged.first { $0.id == "ses_old" }?.started == 9_000)

  // Without a child: shown as starting, with nothing to open, only while the owner runs it.
  let orphan = [try message([call("toolu_orphan", status: "running", ran: 1_000), call("toolu_failed", status: "error", ran: 900)])]
  let starting = ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: orphan, children: [], active: ["ses_root"], shells: [])
  #expect(starting.map(\.id) == ["toolu_orphan"])
  #expect(starting.first?.state == .starting && starting.first?.sessionID == nil && starting.first?.toolID == nil)
  #expect(starting.allSatisfy { !$0.running })
  #expect(ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: orphan, children: [], active: [], shells: []).isEmpty)
}

/// "Agentes e tarefas" tabs: subagents (foreground and background) are agents, background shells are scripts,
/// and a subagent call still being written is a starting agent, never a shell.
@Test func workSeparatesAgentsFromScriptsAndNeverTreatsAShellAsAStartingAgent() throws {
  let message = try JSONDecoder().decode(ConversationMessage.self, from: Data("""
    {"id":"msg_tabs","type":"assistant","agent":"build","time":{"created":1},"content":[
     {"type":"tool","id":"call_bg_agent","name":"subagent","time":{"created":100,"ran":110,"completed":120},
      "state":{"status":"completed","input":{"agent":"explore","description":"Mapear em segundo plano","background":true},
       "content":[{"type":"text","text":"working"}],"metadata":{"sessionID":"ses_bg","status":"running"}}},
     {"type":"tool","id":"call_bg_shell","name":"shell","time":{"created":200,"ran":210,"completed":220},
      "state":{"status":"completed","input":{"command":"bun run dev","background":true},
       "content":[{"type":"text","text":"moved"}],"metadata":{"status":"running","shellID":"sh_dev"}}},
     {"type":"tool","id":"call_done_shell","name":"shell","time":{"created":250,"ran":260,"completed":270},
      "state":{"status":"completed","input":{"command":"make test","background":true},
       "content":[{"type":"text","text":"moved"}],"metadata":{"status":"running","shellID":"sh_test"}}},
     {"type":"tool","id":"call_fg_shell","name":"shell","time":{"created":280,"ran":290,"completed":295},
      "state":{"status":"completed","input":{"command":"ls"},"content":[{"type":"text","text":"a"}],"metadata":{"exit":0}}},
     {"type":"tool","id":"call_writing","name":"subagent","time":{"created":300},
      "state":{"status":"streaming","input":"{\\"agent\\":\\"general\\",\\"description\\":\\"Revisar \\\\\\"tudo\\\\\\"\\",\\"prompt\\":\\"Leia"}},
     {"type":"tool","id":"call_blank","name":"subagent","time":{"created":310},
      "state":{"status":"streaming","input":"{\\"ag"}}
    ]}
    """.utf8))
  let child = try JSONDecoder().decode(Session.self, from: Data("""
    {"id":"ses_bg","parentID":"ses_root","projectID":"p","title":"Mapear","agent":"explore",
     "location":{"directory":"/repo"},"time":{"created":112,"updated":113}}
    """.utf8))
  let shells = try JSONDecoder().decode([ShellInfo].self, from: Data("""
    [{"id":"sh_dev","status":"running","command":"bun run dev","metadata":{"sessionID":"ses_root"},"time":{"started":215}},
     {"id":"sh_test","status":"exited","exit":1,"command":"make test","metadata":{"sessionID":"ses_root"},
      "time":{"started":265,"completed":5265}},
     {"id":"sh_orphan","status":"running","command":"tail -f log","metadata":{"sessionID":"ses_root"},"time":{"started":50}}]
    """.utf8))
  let work = ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: [message], children: [child],
    active: ["ses_root", "ses_bg"], shells: shells)
  let agents = work.filter { $0.kind == .agent }
  let scripts = work.filter { $0.kind == .script }
  #expect(agents.map(\.id) == ["call_blank", "call_writing", "ses_bg"])
  #expect(agents.first { $0.id == "ses_bg" }?.state == .running)
  let writing = try #require(agents.first { $0.id == "call_writing" })
  #expect(writing.state == .starting && writing.agent == "general" && writing.title == #"Revisar "tudo""#)
  let blank = try #require(agents.first { $0.id == "call_blank" })
  #expect(blank.agent == nil && blank.title == "Preparando subagente…" && blank.shellID == nil)
  #expect(scripts.map(\.id) == ["sh_dev", "sh_orphan", "sh_test"])
  #expect(scripts.allSatisfy { $0.state != .starting && $0.agent == nil && $0.sessionID == nil })
  #expect(scripts.first { $0.id == "sh_dev" }?.toolID == "call_bg_shell")
  #expect(scripts.first { $0.id == "sh_dev" }?.title == "bun run dev")
  #expect(scripts.first { $0.id == "sh_test" }?.state == .failed)
  #expect(scripts.first { $0.id == "sh_test" }?.duration == 5000)
  #expect(scripts.first { $0.id == "sh_orphan" }?.state == .running)
  #expect(!agents.contains { $0.shellID != nil })
}

/// Production case (27 Oct): a background subagent started long ago and still running sat below ~30 newer,
/// finished ones. Running work comes first; finished work follows the last time it ran, so a continued child that
/// ended recently is above an older one created later.
@Test func runningAgentsComeFirstAndFinishedOnesFollowTheirLatestActivity() throws {
  func call(_ id: String, ran: Double, completed: Double, child: String, continued: Bool = false) -> String {
    let extra = continued ? #","sessionID":"\#(child)""# : ""
    return """
      {"type":"tool","id":"\(id)","name":"subagent","time":{"created":\(ran - 5),"ran":\(ran),"completed":\(completed)},
       "state":{"status":"completed","input":{"agent":"opushigh","description":"\(id)","background":true\(extra)},
       "content":[{"type":"text","text":"ok"}],"metadata":{"sessionID":"\(child)","status":"running"}}}
      """
  }
  func child(_ id: String, created: Double, idle: Double?, outcome: String?) throws -> Session {
    let idleField = idle.map { #","idle":\#($0)"# } ?? ""
    let outcomeField = outcome.map { #""outcome":"\#($0)","# } ?? ""
    return try JSONDecoder().decode(Session.self, from: Data("""
      {"id":"\(id)","parentID":"ses_root","projectID":"p","title":"\(id)","agent":"opushigh",\(outcomeField)
       "location":{"directory":"/repo"},"time":{"created":\(created),"updated":\((idle ?? created) + 1)\(idleField)}}
      """.utf8))
  }
  let message = try JSONDecoder().decode(ConversationMessage.self, from: Data("""
    {"id":"msg_order","type":"assistant","agent":"build","time":{"created":1},"content":[
     \(call("call_long", ran: 1_000, completed: 1_001, child: "ses_long")),
     \(call("call_new", ran: 5_000, completed: 5_001, child: "ses_new")),
     \(call("call_old", ran: 2_000, completed: 2_001, child: "ses_old")),
     \(call("call_resumed", ran: 8_000, completed: 8_001, child: "ses_old", continued: true)),
     \(call("call_again", ran: 9_000, completed: 9_001, child: "ses_back", continued: true))
    ]}
    """.utf8))
  let children = [
    try child("ses_long", created: 1_002, idle: nil, outcome: nil),
    try child("ses_new", created: 5_002, idle: 6_000, outcome: "succeeded"),
    try child("ses_old", created: 2_002, idle: 8_500, outcome: "succeeded"),
    try child("ses_back", created: 500, idle: 700, outcome: "succeeded"),
  ]
  let work = ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: [message], children: children,
    active: ["ses_long", "ses_back"], shells: [])
  // ses_back was continued at 9 000 and runs; ses_long has run since 1 000; then finished by their last run.
  #expect(work.map(\.id) == ["ses_back", "ses_long", "ses_old", "ses_new"])
  #expect(work.first { $0.id == "ses_back" }?.activity == 9_000)
  #expect(work.first { $0.id == "ses_back" }?.started == 9_000)
  // A long-running background child counts from its call, not from a shell it happens to be running.
  #expect(work.first { $0.id == "ses_long" }?.started == 1_000)
  #expect(work.first { $0.id == "ses_old" }?.activity == 8_500)

  // When the running child finishes, it joins the finished group by when it ended.
  let ended = [try child("ses_long", created: 1_002, idle: 7_000, outcome: "succeeded")] + children.dropFirst()
  #expect(ConversationProjection.work(
    ownerID: "ses_root", viewedID: "ses_root", messages: [message], children: ended,
    active: ["ses_back"], shells: []).map(\.id) == ["ses_back", "ses_old", "ses_long", "ses_new"])
}

/// A subagent continued with another agent or model (same `sessionID`) shows the latest one: the server switches
/// the child's selection before prompting it, so the row follows the child, not the first call.
@Test func continuedSubagentShowsItsLatestAgentAndModel() throws {
  func call(_ id: String, ran: Double, agent: String, model: String?, continued: Bool) -> String {
    let fields = (model.map { #","model":"\#($0)""# } ?? "") + (continued ? #","sessionID":"ses_worker""# : "")
    return """
      {"type":"tool","id":"\(id)","name":"subagent","time":{"created":\(ran - 5),"ran":\(ran),"completed":\(ran + 100)},
       "state":{"status":"completed","input":{"agent":"\(agent)","description":"Worker"\(fields)},
       "content":[{"type":"text","text":"ok"}],"metadata":{"sessionID":"ses_worker"}}}
      """
  }
  func message(_ parts: [String]) throws -> ConversationMessage {
    try JSONDecoder().decode(ConversationMessage.self, from: Data("""
      {"id":"msg_model","type":"assistant","agent":"build","time":{"created":1},"content":[\(parts.joined(separator: ","))]}
      """.utf8))
  }
  func worker(agent: String, model: String, variant: String, ran: (String, String)?) throws -> Session {
    let context = ran.map {
      #","context":{"id":"msg_step","tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"model":{"id":"\#($0.0)","providerID":"p","variant":"\#($0.1)"}}"#
    } ?? ""
    return try JSONDecoder().decode(Session.self, from: Data("""
      {"id":"ses_worker","parentID":"ses_root","projectID":"p","title":"Worker","agent":"\(agent)",
       "model":{"id":"\(model)","providerID":"p","variant":"\(variant)"},"location":{"directory":"/repo"},
       "time":{"created":1003,"updated":3000,"idle":3000}\(context)}
      """.utf8))
  }
  func row(_ messages: [ConversationMessage], _ child: Session) -> SessionWork? {
    ConversationProjection.work(ownerID: "ses_root", viewedID: "ses_root", messages: messages, children: [child],
      active: [], shells: []).first
  }
  let first = try message([call("call_1", ran: 1_000, agent: "worker", model: "p/opus#low", continued: false)])
  // First call: the child runs what it asked for.
  let launched = try #require(row([first], try worker(agent: "worker", model: "opus", variant: "low", ran: ("opus", "low"))))
  #expect(launched.agent == "worker" && launched.model == ModelReference(id: "opus", providerID: "p", variant: "low"))

  let continued = try message([
    call("call_1", ran: 1_000, agent: "worker", model: "p/opus#low", continued: false),
    call("call_2", ran: 2_000, agent: "reviewer", model: "p/terra#low", continued: true),
  ])
  // Continued with another agent and model, before its answer: the switched selection, not the old step.
  let pending = try #require(row([continued], try worker(agent: "reviewer", model: "terra", variant: "low", ran: ("opus", "low"))))
  #expect(pending.agent == "reviewer" && pending.model == ModelReference(id: "terra", providerID: "p", variant: "low"))
  #expect(pending.title == "Worker")
  // After the answer, the step that really ran agrees.
  let answered = try #require(row([continued], try worker(agent: "reviewer", model: "terra", variant: "low", ran: ("terra", "low"))))
  #expect(answered.model == ModelReference(id: "terra", providerID: "p", variant: "low"))

  #expect(ModelReference(selector: "llm-proxy/gpt-6-luna#low") == ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low"))
  #expect(ModelReference(selector: "openrouter/anthropic/claude") == ModelReference(id: "anthropic/claude", providerID: "openrouter"))
  #expect(ModelReference(selector: "nonsense") == nil && ModelReference(selector: "p/") == nil)
  #expect(ModelReference(selector: "") == nil && ModelReference(selector: "#") == nil)
  #expect(ModelReference(selector: "#provider/model") == nil)
}
