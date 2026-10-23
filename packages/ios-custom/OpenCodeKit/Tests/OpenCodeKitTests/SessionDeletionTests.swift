import Foundation
import Testing

@testable import OpenCodeKit

private func deletionSession(_ id: String, parent: String? = nil) throws -> Session {
  var value: [String: JSONValue] = [
    "id": .string(id), "projectID": .string("global"),
    "location": .object(["directory": .string("/owned")]),
    "time": .object(["created": .number(1), "updated": .number(1)]),
  ]
  if let parent { value["parentID"] = .string(parent) }
  return try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(value))
}

@Test func deletionIncludesDescendantsButNeverParentOrSibling() throws {
  let sessions = try [deletionSession("ses_grandchild", parent: "ses_child"),
    deletionSession("ses_parent"), deletionSession("ses_child", parent: "ses_parent"),
    deletionSession("ses_sibling", parent: "ses_parent")]
  #expect(SessionDeletionPlan(sessionID: "ses_child", sessions: sessions).ids == ["ses_child", "ses_grandchild"])
  #expect(SessionDeletionPlan(sessionID: "ses_parent", sessions: sessions).ids.count == 4)
  #expect(SessionDeletionPlan(sessionID: "ses_uncached", sessions: []).ids == ["ses_uncached"])
}

@Test func deletionCleansExactLegacyAndServerQualifiedPreferenceKeys() throws {
  let parent = "ses_parent"
  let encoded = SessionPreferenceKey.encode(parent)
  let other = "[\"http://remote:1234\",\"ses_child\"]"
  let preferences = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode([
    "revision": JSONValue.number(1), "data": .object([
      "projects": .object([:]), "settings": .object(["autoApprove": .bool(false)]),
      "pinnedSessions": .array([.string(parent), .string(encoded), .string("ses_keep")]),
      "mutedSessions": .array([.string(other), .string("invalid")]),
      "masterSessions": .object(["local": .string("ses_master")]),
    ]),
  ]))
  let plan = SessionDeletionPlan(sessionID: parent, sessions: try [deletionSession("ses_child", parent: parent)])
  let intents = try plan.preferenceCleanup(preferences).map {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0))
  }
  #expect(intents.compactMap { $0.object?["session"]?.string } == [parent, encoded, other])
  #expect(intents.compactMap { $0.object?["type"]?.string } == ["sidebar.pin", "sidebar.pin", "sidebar.mute"])
  #expect(intents[0].object?["pinned"] == .bool(false))
  #expect(intents[2].object?["muted"] == .bool(false))
}

@Test func deletionUsesOneBodylessDeleteAndSurfacesFailure() async throws {
  for status in [204, 500] {
    let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { request in
      #expect(request.httpMethod == "DELETE")
      #expect(request.url?.path == "/api/session/ses_parent")
      #expect(request.httpBody == nil)
      return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    do {
      try await client.deleteSession("ses_parent")
      #expect(status == 204)
    } catch ClientError.http(let code) { #expect(code == 500 && status == 500) }
  }
}

@Test @MainActor func deletionRemovesReadingAndExpansionStateWithoutOtherSessions() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let reading = ReadingPositionStore(server: "sandbox", root: root)
  let expansions = ConversationExpansionMemory()
  for id in ["ses_delete", "ses_keep"] {
    reading.set(.init(.message(id: "message", offset: 42)), sessionID: id)
    expansions.set(["tool": true], sessionID: id)
  }
  try reading.remove(["ses_delete"])
  expansions.remove(["ses_delete"])
  #expect(reading.position("ses_delete") == nil)
  #expect(ReadingPositionStore(server: "sandbox", root: root).position("ses_delete") == nil)
  #expect(reading.position("ses_keep") != nil)
  #expect(expansions.values("ses_delete").isEmpty)
  #expect(expansions.values("ses_keep") == ["tool": true])
  var alerts = SessionAlertPolicy(claims: ["sandbox\u{0}ses_delete\u{0}succeeded\u{0}1", "sandbox\u{0}ses_keep\u{0}succeeded\u{0}2"])
  alerts.remove(["ses_delete"])
  #expect(alerts.claims == ["sandbox\u{0}ses_keep\u{0}succeeded\u{0}2"])
  let draft = DraftPersistence(server: "sandbox", sessionID: "ses_delete", root: root)
  try await draft.save(.init(document: .init(text: "rascunho")))
  try await draft.remove()
  #expect(try await draft.load().0 == nil)
}
