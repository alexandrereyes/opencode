import OpenCodeKit
import UIKit
import UserNotifications
import os

/// "Avisar ao terminar": notification permission, the APNs device token and its registration with the connected
/// server (`custom.notifications`), plus presentation and taps of the alerts the server sends when a session with the
/// bell on finishes. Contract: `plugin-app-custom/docs/session-notifications.md`.
@MainActor final class SessionNotificationAgent: NSObject, UNUserNotificationCenterDelegate {
  static let shared = SessionNotificationAgent()
  nonisolated static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "SessionNotifications")
  private var token: String?
  private var client: OpenCodeClient?
  /// Servers that accepted this device's token and have APNs configured, so a bell session's finish arrives as a
  /// system notification and the in-app banner skips it.
  private(set) var pushing: Set<URL> = []

  /// Called before the app finishes launching, so a tap that cold-launches the app still reaches the delegate.
  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  /// Asks for permission the first time a bell is turned on (never at launch); afterwards it only reads the status.
  func authorize() async -> Bool {
    let center = UNUserNotificationCenter.current()
    let status = await center.notificationSettings().authorizationStatus
    switch status {
    case .authorized, .provisional, .ephemeral:
      UIApplication.shared.registerForRemoteNotifications()
      return true
    case .notDetermined:
      do {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
      } catch {
        Self.log.error("authorization: \(error.localizedDescription, privacy: .public)")
        return false
      }
    default: return false
    }
  }

  /// Every event-stream (re)connection: while notifications are authorized, the token is registered again, since
  /// APNs may rotate it and a server may have forgotten it.
  func connected(_ client: OpenCodeClient) {
    #if DEBUG
    guard ScrollFixtures.mode != "catalog" else { return }
    #endif
    if self.client?.configuration.url != client.configuration.url { pushing = [] }
    self.client = client
    Task {
      let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
      guard [.authorized, .provisional, .ephemeral].contains(status) else { return }
      if token == nil { UIApplication.shared.registerForRemoteNotifications() } else { await send() }
    }
  }

  func received(token data: Data) {
    token = data.hexToken
    Task { await send() }
  }

  private func send() async {
    guard let client, let token else { return }
    let url = client.configuration.url
    do {
      let push = try await client.notificationsRegister(deviceID: DeviceAgent.shared.preferences.deviceID,
        serverKey: AgentsActivityAgent.serverKey(AppRuntime.shared.servers),
        environment: AgentsActivityAgent.shared.environment, token: token)
      if push == .configured { pushing.insert(url) } else { pushing.remove(url) }
      Self.log.notice("registered push=\(push.rawValue, privacy: .public)")
    } catch {
      pushing.remove(url)
      Self.log.debug("register failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
    async -> UNNotificationPresentationOptions
  {
    guard let alert = SessionFinishedAlert(userInfo: notification.request.content.userInfo) else {
      return [.banner, .list, .sound]
    }
    return await MainActor.run {
      let runtime = AppRuntime.shared
      // The delegate only asks while the app is in the foreground.
      let shown = alert.presents(foreground: true, serverKey: AgentsActivityAgent.serverKey(runtime.servers),
        openSessionID: runtime.store?.currentSessionID)
      return shown ? [.banner, .list, .sound] : []
    }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse)
    async
  {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let alert = SessionFinishedAlert(userInfo: response.notification.request.content.userInfo)
    else { return }
    await AppRuntime.shared.open(alert.link)
  }
}

/// The app delegate: background downloads (`TranscriptionAppDelegate`) plus the remote-notification callbacks.
final class AppDelegate: TranscriptionAppDelegate {
  func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
  {
    SessionNotificationAgent.shared.install()
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    SessionNotificationAgent.shared.received(token: deviceToken)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
    SessionNotificationAgent.log.error("remote notifications: \(error.localizedDescription, privacy: .public)")
  }
}
