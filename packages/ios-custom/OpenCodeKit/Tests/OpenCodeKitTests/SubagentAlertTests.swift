import Foundation
import Testing

@testable import OpenCodeKit

private func alertSession(_ id: String = "ses_root", parent: String? = nil) throws -> Session {
  let value: JSONValue = .object([
    "id": .string(id), "parentID": parent.map(JSONValue.string) ?? .null,
    "projectID": .string("project"), "location": .object(["directory": .string("/sandbox")]),
    "agent": .string(parent == nil ? "build" : "explore"),
    "time": .object(["created": .number(1), "updated": .number(2)]),
  ])
  return try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(value))
}
private func alertEvent(_ type: String = "session.execution.succeeded", owner: String = "ses_root", at: Double = 100, id: String = "req_one") throws -> ConversationEvent {
  let data: JSONValue = type == "form.created" ? .object([
    "form": .object(["id": .string(id), "sessionID": .string(owner),
      "metadata": .object(["kind": .string("question")])]),
  ]) : .object(["sessionID": .string(owner), "id": .string(id)])
  return try JSONDecoder().decode(ConversationEvent.self, from: JSONEncoder().encode(JSONValue.object([
    "id": .string("evt_" + id), "type": .string(type), "created": .number(at), "data": data,
  ])))
}

@Test func alertsOnlyAnnounceAnotherRootAndRealTerminalOutcomes() throws {
  let root = try alertSession()
  let child = try alertSession("ses_child", parent: root.id)
  for type in ["session.execution.succeeded", "session.execution.failed"] {
    for current in [root.id, "ses_other", nil] {
      var policy = SessionAlertPolicy()
      policy.connect(at: 10)
      let signal = try #require(SessionAlertSignal(alertEvent(type)))
      #expect(policy.admit(signal, server: "a", session: root, root: root, current: current) == (current != root.id))
    }
    var policy = SessionAlertPolicy()
    policy.connect(at: 10)
    #expect(policy.admit(try #require(SessionAlertSignal(alertEvent(type, owner: child.id))), server: "a", session: child, root: root, current: nil) == false)
  }
  for type in ["session.execution.interrupted", "session.step.failed", "session.tool.failed", "session.execution.started", "rpc.custom.navigation.updated"] {
    #expect(try SessionAlertSignal(alertEvent(type)) == nil)
  }
}

@Test func requestsRollUpButRespectCurrentOwnerAndAutoApprove() throws {
  let root = try alertSession()
  let child = try alertSession("ses_child", parent: root.id)
  for type in ["permission.asked", "form.created"] {
    let signal = try #require(SessionAlertSignal(alertEvent(type, owner: child.id)))
    // A bell (pushed by the server) only replaces finish alerts: requests still alert in the app.
    for (current, notified, expected) in [
      (nil, [String](), true), (root.id, [], false), (child.id, [], false),
      (nil, [SessionPreferenceKey.encode(root.id)], true),
    ] {
      var policy = SessionAlertPolicy()
      policy.connect(at: 10)
      #expect(policy.admit(signal, server: "a", session: child, root: root, current: current, notified: notified) == expected)
    }
    var policy = SessionAlertPolicy()
    policy.connect(at: 10)
    #expect(policy.admit(signal, server: "a", session: child, root: root, current: nil, autoApprove: true) == (type == "form.created"))
  }
}

@Test func reconnectAndRefreshNeverBulkReplayOldAlertsAndClaimsSurvive() throws {
  let root = try alertSession()
  var policy = SessionAlertPolicy()
  let signal = try #require(SessionAlertSignal(alertEvent()))
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil) == false)
  policy.connect(at: 50)
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil) == true)
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil) == false)
  policy.disconnect()
  policy.connect(at: 200)
  for time in [101.0, 130, 199] {
    #expect(policy.admit(try #require(SessionAlertSignal(alertEvent(at: time))), server: "a", session: root, root: root, current: nil) == false)
  }
  var restored = SessionAlertPolicy(claims: policy.claims)
  restored.connect(at: 50)
  #expect(restored.admit(signal, server: "a", session: root, root: root, current: nil) == false)
  #expect(restored.admit(signal, server: "b", session: root, root: root, current: nil) == true)
  #expect(restored.admit(try #require(SessionAlertSignal(alertEvent("session.execution.failed"))), server: "a", session: root, root: root, current: nil) == true)
}

@Test func suppressedRequestsAreClaimedAndEnvelopeIDsDoNotReplayThem() throws {
  let root = try alertSession()
  var policy = SessionAlertPolicy()
  policy.connect(at: 50)
  let signal = try #require(SessionAlertSignal(alertEvent("permission.asked")))
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: root.id) == false)
  let duplicate = try #require(SessionAlertSignal(alertEvent("permission.asked", at: 120)))
  #expect(policy.admit(duplicate, server: "a", session: root, root: root, current: nil) == false)
  #expect(policy.admit(try #require(SessionAlertSignal(alertEvent("permission.asked", id: "req_two"))), server: "a", session: root, root: root, current: nil) == true)
}

private func alertShell(_ id: String, owner: String, status: String = "running") throws -> ShellInfo {
  try JSONDecoder().decode(ShellInfo.self, from: Data("""
    {"id":"\(id)","status":"\(status)","command":"sleep 60","metadata":{"sessionID":"\(owner)"},"time":{"started":1}}
    """.utf8))
}

@Test func rootCompletionSaysRepliedWhileItsFamilyStillRuns() throws {
  let root = try alertSession()
  let child = try alertSession("ses_child", parent: root.id)
  let other = try alertSession("ses_child2", parent: root.id)
  let grandchild = try alertSession("ses_grand", parent: child.id)
  func label(_ active: [Session], _ shells: [ShellInfo] = []) -> SessionAlertContent {
    SessionAlertContent(kind: .succeeded, work: SessionAlertWork(root: root.id, active: active, shells: shells))
  }
  #expect(label([]).label == "Concluída")
  #expect(label([]).tone == .success)
  #expect(label([]).replied == false)
  #expect(label([child]).label == "Respondeu · 1 agente rodando")
  #expect(label([child]).tone == .neutral)
  // A running orchestrator child and its running child count once, like the header.
  #expect(label([child, grandchild]).label == "Respondeu · 1 agente rodando")
  #expect(label([child, other]).label == "Respondeu · 2 agentes rodando")
  // An idle child's still running child keeps the root from being done.
  #expect(label([grandchild]).label == "Respondeu · 1 agente rodando")
  let shell = try alertShell("sh_one", owner: root.id)
  #expect(label([], [shell]).label == "Respondeu · 1 tarefa rodando")
  #expect(label([], [shell, try alertShell("sh_two", owner: root.id)]).label == "Respondeu · 2 tarefas rodando")
  #expect(label([child], [shell]).label == "Respondeu · 1 agente e 1 tarefa rodando")
  // Finished shells and shells of other sessions are not this root's background work.
  #expect(label([], [try alertShell("sh_done", owner: root.id, status: "exited"), try alertShell("sh_child", owner: child.id)]).label == "Concluída")
  // Unknown remaining work never claims completion.
  let unknown = SessionAlertContent(kind: .succeeded)
  #expect(unknown.label == "Respondeu")
  #expect(unknown.tone == .neutral)
  for (kind, text, tone) in [(SessionAlertKind.failed, "Falhou", SessionAlertContent.Tone.error), (.permission, "Precisa de você", .error), (.question, "Precisa de você", .info)] {
    let content = SessionAlertContent(kind: kind, work: SessionAlertWork(agents: 2, tasks: 1), preview: "Ignorada")
    #expect(content.label == text)
    #expect(content.tone == tone)
    #expect(content.preview == nil)
  }
}

@Test func alertPreviewIsTheLatestReplyFirstLineOrNothing() throws {
  func preview(_ messages: String) throws -> SessionPreview {
    SessionPreview(messages: try JSONDecoder().decode([TranscriptMessage].self, from: Data(messages.utf8)))
  }
  let reply = try preview("""
    [{"id":"msg_u","type":"user","text":"Faça","time":{"created":1}},
     {"id":"msg_a","type":"assistant","time":{"created":2},"content":[{"type":"text","text":"\\n  Pronto, terminei.  \\nSegunda linha"}]}]
    """)
  #expect(reply.reply == "Pronto, terminei.")
  #expect(SessionAlertContent(kind: .succeeded, work: SessionAlertWork(agents: 0, tasks: 0), preview: reply.reply).preview == "Pronto, terminei.")
  let userLast = try preview("""
    [{"id":"msg_a","type":"assistant","time":{"created":1},"content":[{"type":"text","text":"Antes"}]},
     {"id":"msg_u","type":"user","text":"Outra coisa","time":{"created":2}}]
    """)
  #expect(userLast.reply == nil)
  #expect(SessionAlertContent(kind: .succeeded, work: nil, preview: userLast.reply).preview == nil)
  let long = try preview("""
    [{"id":"msg_a","type":"assistant","time":{"created":1},"content":[{"type":"text","text":"\(String(repeating: "a", count: 300))"}]}]
    """)
  #expect(long.reply?.count == 240)
}

private actor ChildActions: ConversationActions {
  var calls: [String] = []
  var bodies: [PromptRequest] = []
  func session(_ id: String) throws -> Session {
    Issue.record("Child submissions must not read or switch the agent")
    return try alertSession()
  }
  func selectAgent(_ agent: String, sessionID: String) { calls.append("agent") }
  func selectModel(_ model: ModelReference, sessionID: String) { calls.append("model:" + sessionID) }
  func prompt(_ request: PromptRequest, sessionID: String) {
    calls.append("prompt:" + sessionID)
    bodies.append(request)
  }
  func cancelInbox(_ id: String, sessionID: String) { calls.append("cancel:" + sessionID) }
}

@Test func childSubmissionKeepsItsAgentAndUsesItsOwnBusyState() async throws {
  let model = ModelReference(id: "gpt-6-luna", providerID: "llm-proxy", variant: "low")
  for busy in [false, true] {
    let actions = ChildActions()
    // A busy parent is deliberately irrelevant: only the child's execution selects delivery.
    let request = PromptRequest(id: "msg_child", text: "Responda oi", delivery: PromptDelivery.choose(busy: busy, preference: .queue), agent: "explore", model: model)
    let submission = PromptSubmission(request: request, sessionID: "ses_child", agent: "explore", model: model, keepsAgent: true)
    try await submission.send(using: actions)
    #expect(await actions.calls == (busy ? ["prompt:ses_child"] : ["model:ses_child", "prompt:ses_child"]))
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(try #require(await actions.bodies.first)))
    #expect(encoded.object?["agent"] == nil)
    #expect(encoded.object?["metadata"]?.object?["agent"]?.string == "explore")
    #expect(encoded.object?["delivery"]?.string == (busy ? "queue" : "steer"))
    #expect(encoded.object?["id"]?.string == "msg_child")
  }
}

@Test func modelDisplayFallbackUsesLastCatalogAndProviderIdentity() throws {
  let models = try JSONDecoder().decode([ModelInfo].self, from: Data("""
    [{"id":"gpt-6-luna","providerID":"llm-proxy","name":"Luna 6","limit":{"context":1050000}},
     {"id":"gpt-6-luna","providerID":"other","name":"Outra Luna","limit":{"context":1}}]
    """.utf8))
  let message = try JSONDecoder().decode(ConversationMessage.self, from: Data("""
    {"id":"msg_footer","type":"assistant","agent":"build","model":{"id":"gpt-6-luna","providerID":"llm-proxy","variant":"low"},"time":{"created":1,"completed":2},"content":[]}
    """.utf8))
  let missingLocation = ModelCatalog.merging([], fallback: models)
  #expect(ConversationProjection.footer(message, models: missingLocation).hasPrefix("Luna 6 · low ·"))
  #expect(ConversationProjection.footer(message, models: [models[1]]).hasPrefix("gpt-6-luna · low ·"))
  #expect(ModelCatalog.merging([models[0]], fallback: models).count == 2)
}

@Test func defaultCatalogDoesNotUseTheMissingSessionLocation() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    #expect(request.url?.path == "/api/model")
    #expect(request.url?.query == nil)
    return (Data("{\"data\":[]}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.models().isEmpty)
}

@Test func bellSessionsFinishThroughTheSystemNotificationInstead() throws {
  let root = try alertSession()
  for type in ["session.execution.succeeded", "session.execution.failed"] {
    let signal = try #require(SessionAlertSignal(alertEvent(type)))
    var policy = SessionAlertPolicy()
    policy.connect(at: 10)
    #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil,
      notified: [SessionPreferenceKey.encode(root.id)]) == false)
    var plain = SessionAlertPolicy()
    plain.connect(at: 10)
    #expect(plain.admit(signal, server: "a", session: root, root: root, current: nil, notified: ["ses_other"]) == true)
  }
}
