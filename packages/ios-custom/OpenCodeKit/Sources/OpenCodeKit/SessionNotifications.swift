import Foundation

/// The `opencode` part of a session alert the server pushes: a bell session's success (`session.finished`), or a
/// question, permission or failure of any top-level session (`session.attention`).
/// Contract: `plugin-app-custom/docs/session-notifications.md`.
public struct SessionPushAlert: Equatable, Sendable {
  public enum Kind: String, Sendable { case finished, question, permission, failed }
  public let kind: Kind
  public let serverKey: String
  public let sessionID: String
  public let directory: String
  /// The pending question or permission, for opening the session at it.
  public let requestID: String?

  public init(kind: Kind, serverKey: String, sessionID: String, directory: String, requestID: String? = nil) {
    self.kind = kind
    self.serverKey = serverKey
    self.sessionID = sessionID
    self.directory = directory
    self.requestID = requestID
  }

  /// `nil` for any other notification.
  public init?(userInfo: [AnyHashable: Any]) {
    guard let payload = userInfo["opencode"] as? [String: Any], let serverKey = payload["serverKey"] as? String,
      let sessionID = payload["sessionID"] as? String
    else { return nil }
    let kind: Kind? = switch payload["kind"] as? String {
    // Servers before the attention alerts also sent a bell session's failure as a finish.
    case "session.finished": payload["outcome"] as? String == "failed" ? .failed : .finished
    case "session.attention": (payload["attention"] as? String).flatMap(Kind.init(rawValue:))
    default: nil
    }
    guard let kind, kind != .finished || payload["outcome"] as? String == "succeeded" else { return nil }
    self.init(kind: kind, serverKey: serverKey, sessionID: sessionID, directory: payload["directory"] as? String ?? "",
      requestID: payload["requestID"] as? String)
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
