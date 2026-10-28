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
  let alert = try #require(SessionFinishedAlert(userInfo: payload))
  #expect(alert == SessionFinishedAlert(serverKey: "mac-principal", sessionID: "ses_a", directory: "/repo", outcome: .succeeded))
  #expect(alert.link == .session(serverKey: "mac-principal", sessionID: "ses_a", directory: "/repo"))
  #expect(SessionFinishedAlert(userInfo: ["aps": ["alert": "x"]]) == nil)
  var other = payload
  other["opencode"] = ["kind": "something.else", "serverKey": "a", "sessionID": "b", "outcome": "succeeded"]
  #expect(SessionFinishedAlert(userInfo: other) == nil)
  var interrupted = payload
  interrupted["opencode"] = ["kind": "session.finished", "serverKey": "a", "sessionID": "b", "outcome": "interrupted"]
  #expect(SessionFinishedAlert(userInfo: interrupted) == nil)
}

@Test func finishedAlertHidesOnlyWhileThatSessionIsOpenInTheForeground() throws {
  let alert = try #require(SessionFinishedAlert(userInfo: payload))
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
