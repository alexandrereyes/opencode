import AppKit
import OpenCodeKit
import UserNotifications

/// The Mac's side of the session alerts: while the app is not in front, each in-app banner of `SessionAlertCenter`
/// (an answer, a failure, a permission or a question, with its mutes and deduplication) also becomes a macOS
/// notification; clicking it brings the app forward on that session. The Dock icon counts the permissions and
/// questions waiting, like the iPhone's tab badge. The fixture never asks for permission or posts anything.
@MainActor final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = MacNotifications()
  private var authorized: Bool?

  /// Asks once per launch, the first time there is something to notify.
  private func authorize() async -> Bool {
    if let authorized { return authorized }
    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    authorized = granted
    return granted
  }

  func start() {
    guard !MacLaunch.fixture else { return }
    UNUserNotificationCenter.current().delegate = self
  }

  func post(_ message: SessionAlertCenter.Message, server: URL) {
    guard !MacLaunch.fixture, !NSApp.isActive else { return }
    let notification = SessionAlertNotification(title: message.session.displayTitle, content: message.content)
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = message.content.kind == .succeeded ? nil : .default
    content.threadIdentifier = message.session.id
    content.userInfo = ["sessionID": message.session.id, "server": server.absoluteString]
    let request = UNNotificationRequest(identifier: message.id.uuidString, content: content, trigger: nil)
    Task {
      guard await authorize() else { return }
      try? await UNUserNotificationCenter.current().add(request)
    }
  }

  func badge(_ count: Int) {
    NSApp.dockTile.badgeLabel = SessionAlertNotification.badge(count)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    guard let id = info["sessionID"] as? String else { return }
    let server = info["server"] as? String
    await MainActor.run {
      NSApp.activate(ignoringOtherApps: true)
      let runtime = MacRuntime.shared
      guard let store = runtime.store, server == nil || store.client.configuration.url.absoluteString == server else {
        return
      }
      store.alerts.openingSession()
      store.conversationPath = [.init(id: id)]
    }
  }

  /// In front, the in-app banner already shows it.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [] }
}
