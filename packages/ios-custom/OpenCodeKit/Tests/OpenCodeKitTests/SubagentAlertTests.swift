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
      #expect(policy.admit(signal, server: "a", session: root, root: root, current: current, muted: []) == (current != root.id))
    }
    var policy = SessionAlertPolicy()
    policy.connect(at: 10)
    #expect(policy.admit(try #require(SessionAlertSignal(alertEvent(type, owner: child.id))), server: "a", session: child, root: root, current: nil, muted: []) == false)
  }
  for type in ["session.execution.interrupted", "session.step.failed", "session.tool.failed", "session.execution.started", "rpc.custom.navigation.updated"] {
    #expect(try SessionAlertSignal(alertEvent(type)) == nil)
  }
}

@Test func requestsRollUpButRespectCurrentOwnerRootMuteAndAutoApprove() throws {
  let root = try alertSession()
  let child = try alertSession("ses_child", parent: root.id)
  for type in ["permission.asked", "form.created"] {
    let signal = try #require(SessionAlertSignal(alertEvent(type, owner: child.id)))
    for (current, muted, expected) in [
      (nil, [String](), true), (root.id, [], false), (child.id, [], false),
      (nil, [SessionPreferenceKey.encode(root.id)], false),
      (nil, [SessionPreferenceKey.encode(child.id)], false),
    ] {
      var policy = SessionAlertPolicy()
      policy.connect(at: 10)
      #expect(policy.admit(signal, server: "a", session: child, root: root, current: current, muted: muted) == expected)
    }
    var policy = SessionAlertPolicy()
    policy.connect(at: 10)
    #expect(policy.admit(signal, server: "a", session: child, root: root, current: nil, muted: [], autoApprove: true) == (type == "form.created"))
  }
}

@Test func reconnectAndRefreshNeverBulkReplayOldAlertsAndClaimsSurvive() throws {
  let root = try alertSession()
  var policy = SessionAlertPolicy()
  let signal = try #require(SessionAlertSignal(alertEvent()))
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil, muted: []) == false)
  policy.connect(at: 50)
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil, muted: []) == true)
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: nil, muted: []) == false)
  policy.disconnect()
  policy.connect(at: 200)
  for time in [101.0, 130, 199] {
    #expect(policy.admit(try #require(SessionAlertSignal(alertEvent(at: time))), server: "a", session: root, root: root, current: nil, muted: []) == false)
  }
  var restored = SessionAlertPolicy(claims: policy.claims)
  restored.connect(at: 50)
  #expect(restored.admit(signal, server: "a", session: root, root: root, current: nil, muted: []) == false)
  #expect(restored.admit(signal, server: "b", session: root, root: root, current: nil, muted: []) == true)
  #expect(restored.admit(try #require(SessionAlertSignal(alertEvent("session.execution.failed"))), server: "a", session: root, root: root, current: nil, muted: []) == true)
}

@Test func suppressedRequestsAreClaimedAndEnvelopeIDsDoNotReplayThem() throws {
  let root = try alertSession()
  var policy = SessionAlertPolicy()
  policy.connect(at: 50)
  let signal = try #require(SessionAlertSignal(alertEvent("permission.asked")))
  #expect(policy.admit(signal, server: "a", session: root, root: root, current: root.id, muted: []) == false)
  let duplicate = try #require(SessionAlertSignal(alertEvent("permission.asked", at: 120)))
  #expect(policy.admit(duplicate, server: "a", session: root, root: root, current: nil, muted: []) == false)
  #expect(policy.admit(try #require(SessionAlertSignal(alertEvent("permission.asked", id: "req_two"))), server: "a", session: root, root: root, current: nil, muted: []) == true)
}

private actor ChildActions: ConversationActions {
  var calls: [String] = []
  var bodies: [PromptRequest] = []
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
