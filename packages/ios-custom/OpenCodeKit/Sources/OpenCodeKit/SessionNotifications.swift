import Foundation

/// The `opencode` part of a "Avisar ao terminar" alert. Contract: `plugin-app-custom/docs/session-notifications.md`.
public struct SessionFinishedAlert: Equatable, Sendable {
  public enum Outcome: String, Sendable { case succeeded, failed }
  public let serverKey: String
  public let sessionID: String
  public let directory: String
  public let outcome: Outcome

  public init(serverKey: String, sessionID: String, directory: String, outcome: Outcome) {
    self.serverKey = serverKey
    self.sessionID = sessionID
    self.directory = directory
    self.outcome = outcome
  }

  /// `nil` for any other notification.
  public init?(userInfo: [AnyHashable: Any]) {
    guard let payload = userInfo["opencode"] as? [String: Any], payload["kind"] as? String == "session.finished",
      let serverKey = payload["serverKey"] as? String, let sessionID = payload["sessionID"] as? String,
      let outcome = (payload["outcome"] as? String).flatMap(Outcome.init(rawValue:))
    else { return nil }
    self.init(serverKey: serverKey, sessionID: sessionID, directory: payload["directory"] as? String ?? "",
      outcome: outcome)
  }

  /// The deep link a tap follows: the session, on the server that sent it.
  public var link: AgentsDeepLink { .session(serverKey: serverKey, sessionID: sessionID, directory: directory) }

  /// Hidden only while he is looking at it: the app in the foreground with this session open on the same server.
  public func presents(foreground: Bool, serverKey: String, openSessionID: String?) -> Bool {
    !(foreground && serverKey == self.serverKey && openSessionID == sessionID)
  }
}

public enum NotificationPush: String, Decodable, Sendable { case configured, unconfigured }

public extension OpenCodeClient {
  func notificationsRegister(deviceID: String, serverKey: String, environment: PushEnvironment, token: String)
    async throws -> NotificationPush
  {
    struct Input: Encodable {
      let deviceID: String
      let serverKey: String
      let environment: PushEnvironment
      let token: String
    }
    struct Output: Decodable { let push: NotificationPush }
    let output: Output = try await rpc("custom.notifications", "register",
      input: Input(deviceID: deviceID, serverKey: serverKey, environment: environment, token: token), timeout: 8)
    return output.push
  }
  func notificationsUnregister(deviceID: String) async throws {
    struct Input: Encodable { let deviceID: String }
    let _: JSONValue = try await rpc("custom.notifications", "unregister", input: Input(deviceID: deviceID), timeout: 8)
  }
}
