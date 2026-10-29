import OpenCodeKit
import UIKit
import UserNotifications
import os

/// Session alerts: notification permission, the APNs device token and its registration with the connected server
/// (`custom.notifications`), plus presentation and taps of the alerts the server sends (questions, permissions and
/// failures of any session, and finishes of sessions with "Avisar ao terminar").
/// Contract: `plugin-app-custom/docs/session-notifications.md`.
@MainActor final class SessionNotificationAgent: NSObject, UNUserNotificationCenterDelegate {
  static let shared = SessionNotificationAgent()
  nonisolated static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "SessionNotifications")
  private var token: String?
  private var client: OpenCodeClient?
  /// Servers that accepted this device's token and have APNs configured, so their alerts arrive as system
  /// notifications and the in-app banner skips them.
  private(set) var pushing: Set<URL> = []

  /// Called before the app finishes launching, so a tap that cold-launches the app still reaches the delegate.
  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  /// Asks for permission (the first bell, or yes to `offer`), never at launch; afterwards it only reads the status.
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

  /// The one-time offer outside the bell: the first time a question or permission waits while notifications were
  /// never asked for (not on launch, and not in sandbox runs unless `-OpenCodeNotificationOffer` asks for it).
  func shouldOffer() async -> Bool {
    guard !UserDefaults.standard.bool(forKey: Self.offeredKey) else { return false }
    let runtime = AppRuntime.shared
    guard runtime.servers.launchOverride == nil || ProcessInfo.processInfo.arguments.contains("-OpenCodeNotificationOffer")
    else { return false }
    return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
  }

  /// Either answer is final: "Agora não" leaves the bell as the only way to ask again.
  func answerOffer(accept: Bool, client: OpenCodeClient) async {
    UserDefaults.standard.set(true, forKey: Self.offeredKey)
    guard accept, await authorize() else { return }
    connected(client)
  }

  private static let offeredKey = "OpenCodeNotificationsOffered"

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
    guard let alert = SessionPushAlert(userInfo: notification.request.content.userInfo) else {
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
      let alert = SessionPushAlert(userInfo: response.notification.request.content.userInfo)
    else { return }
    await AppRuntime.shared.open(alert.link, request: alert.requestID)
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
