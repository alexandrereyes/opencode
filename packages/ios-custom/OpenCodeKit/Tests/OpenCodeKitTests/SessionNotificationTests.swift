import Foundation
import Testing
@testable import OpenCodeKit

/// The `opencode` payload the plugin's `notifications/index.ts` builds (`docs/session-notifications.md`).
private var payload: [AnyHashable: Any] { [
  "aps": ["alert": ["title": "Corrigir login", "body": "Terminou · app-custom"], "thread-id": "ses_a"],
  "opencode": ["kind": "session.finished", "serverKey": "mac-principal", "sessionID": "ses_a",
    "directory": "/repo", "outcome": "succeeded"],
] }

@Test func finishedAlertDecodesTheServerPayloadAndIgnoresOthers() throws {
  let alert = try #require(SessionPushAlert(userInfo: payload))
  #expect(alert == SessionPushAlert(kind: .finished, serverKey: "mac-principal", sessionID: "ses_a", directory: "/repo"))
  #expect(alert.link == .session(serverKey: "mac-principal", sessionID: "ses_a", directory: "/repo"))
  #expect(alert.requestID == nil)
  #expect(SessionPushAlert(userInfo: ["aps": ["alert": "x"]]) == nil)
  var other = payload
  other["opencode"] = ["kind": "something.else", "serverKey": "a", "sessionID": "b", "outcome": "succeeded"]
  #expect(SessionPushAlert(userInfo: other) == nil)
  var interrupted = payload
  interrupted["opencode"] = ["kind": "session.finished", "serverKey": "a", "sessionID": "b", "outcome": "interrupted"]
  #expect(SessionPushAlert(userInfo: interrupted) == nil)
  // An older server's bell failure.
  var failed = payload
  failed["opencode"] = ["kind": "session.finished", "serverKey": "a", "sessionID": "b", "outcome": "failed"]
  #expect(SessionPushAlert(userInfo: failed)?.kind == .failed)
}

@Test func attentionAlertsCarryTheirKindAndRequest() throws {
  for (attention, kind, request) in [("question", SessionPushAlert.Kind.question, "frm_1"),
    ("permission", .permission, "per_1"), ("failed", .failed, nil)] as [(String, SessionPushAlert.Kind, String?)] {
    var opencode: [String: Any] = ["kind": "session.attention", "serverKey": "mac-principal", "sessionID": "ses_a",
      "directory": "/repo", "attention": attention]
    if let request { opencode["requestID"] = request }
    let alert = try #require(SessionPushAlert(userInfo: ["aps": ["interruption-level": "active"], "opencode": opencode]))
    #expect(alert == SessionPushAlert(kind: kind, serverKey: "mac-principal", sessionID: "ses_a", directory: "/repo",
      requestID: request))
  }
  let unknown: [String: Any] = ["kind": "session.attention", "serverKey": "a", "sessionID": "b", "attention": "other"]
  #expect(SessionPushAlert(userInfo: ["opencode": unknown]) == nil)
}

@Test func finishedAlertHidesOnlyWhileThatSessionIsOpenInTheForeground() throws {
  let alert = try #require(SessionPushAlert(userInfo: payload))
  #expect(!alert.presents(foreground: true, serverKey: "mac-principal", openSessionID: "ses_a"))
  #expect(alert.presents(foreground: true, serverKey: "mac-principal", openSessionID: "ses_b"))
  #expect(alert.presents(foreground: true, serverKey: "mac-principal", openSessionID: nil))
  #expect(alert.presents(foreground: true, serverKey: "outro-mac", openSessionID: "ses_a"))
  #expect(alert.presents(foreground: false, serverKey: "mac-principal", openSessionID: "ses_a"))
}

@Test func registrationSendsTheContractInput() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    #expect(request.url?.path == "/api/rpc/custom.notifications/register")
    let input = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!).object?["input"]
    #expect(input == .object(["deviceID": .string("d"), "serverKey": .string("k"),
      "environment": .string("sandbox"), "token": .string("ab12")]))
    let body = #"{"output":{"push":"configured"}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.notificationsRegister(deviceID: "d", serverKey: "k", environment: .sandbox, token: "ab12") == .configured)
}
