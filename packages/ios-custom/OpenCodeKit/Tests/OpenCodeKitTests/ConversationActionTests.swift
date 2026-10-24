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
  #expect(all.map(\.created) == all.map(\.created).sorted(by: >))
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
  #expect(work.map(\.id) == ["ses_failed", "ses_stopped", "ses_running", "ses_done", "ses_unknown"])
  #expect(work.map(\.state) == [.failed, .interrupted, .running, .completed, .ended])
  #expect(work.first { $0.id == "ses_done" }?.duration == 60_000)
  #expect(work.first { $0.id == "ses_running" }?.duration == nil)
  #expect(work.map(\.state.label) == ["Erro", "Interrompido", "Em execução", "Concluído", "Encerrado"])
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
