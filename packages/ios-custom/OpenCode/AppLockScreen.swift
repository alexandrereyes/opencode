import OpenCodeKit
import SwiftUI
import UIKit

/// Covers the whole scene while `AppLock.covered` (locked, or the lock on and the scene inactive or prompting): its own window above every other one, so sheets, full-screen
/// covers, alerts and the composer are hidden and out of reach (touches, VoiceOver, hardware keys), and the app
/// switcher's snapshot shows only the cover. The scene's lifecycle notifications drive the lock synchronously,
/// before the snapshot; the store, voice, Live Activities and background work never notice it.
@MainActor final class AppLockScreen {
  static let shared = AppLockScreen()
  let lock: AppLock
  private var window: UIWindow?

  private init() {
    #if DEBUG
    lock = AppLock(authenticator: AppLockFixture.authenticator ?? FaceIDAuthenticator())
    #else
    lock = AppLock(authenticator: FaceIDAuthenticator())
    #endif
  }

  /// From `App.init`, before the scene connects, so a launch with the lock on is covered from its first frame.
  func install() {
    observe(UIScene.willConnectNotification) { scene in self.attach(scene) }
    observe(UIScene.willDeactivateNotification) { _ in self.lock.sceneWillDeactivate() }
    observe(UIScene.didEnterBackgroundNotification) { _ in self.lock.sceneDidEnterBackground() }
    observe(UIScene.didActivateNotification) { _ in self.lock.sceneDidActivate() }
    // Unlocking, prompts and turning the lock off happen outside the notifications.
    Task { for await _ in Observations({ self.lock.covered }) { self.refresh() } }
  }

  private func observe(_ name: Notification.Name, _ handle: @escaping @MainActor (UIWindowScene) -> Void) {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
      // Delivered on the main queue, synchronously with the transition: the cover must be up before the snapshot.
      nonisolated(unsafe) let object = note.object
      MainActor.assumeIsolated {
        guard let scene = object as? UIWindowScene, scene.session.role == .windowApplication else { return }
        handle(scene)
        self.refresh()
      }
    }
  }

  /// Also after iOS disconnects the scene in the background and connects a new one: the cover follows it.
  private func attach(_ scene: UIWindowScene) {
    guard window?.windowScene !== scene else { return }
    let window = UIWindow(windowScene: scene)
    window.windowLevel = .alert + 1
    let host = UIHostingController(rootView: AppLockView(lock: lock))
    host.view.accessibilityViewIsModal = true
    window.rootViewController = host
    window.isHidden = true
    self.window = window
  }

  private func refresh() {
    guard let window, let scene = window.windowScene else { return }
    let others = scene.windows.filter { $0 !== window }
    if lock.covered {
      for other in others {
        other.endEditing(true)
        other.accessibilityElementsHidden = true
      }
      window.isHidden = false
      window.makeKey()
      window.layoutIfNeeded()
    } else if !window.isHidden {
      window.isHidden = true
      for other in others { other.accessibilityElementsHidden = false }
      others.first { !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
    }
  }
}

private struct AppLockView: View {
  @Environment(\.colorScheme) private var systemScheme
  let lock: AppLock
  var body: some View {
    let appearance = AppRuntime.shared.appearance
    let theme = appearance.theme(systemDark: systemScheme == .dark)
    VStack(spacing: 18) {
      Image(systemName: "faceid").font(.system(size: 54, weight: .light)).foregroundStyle(theme.color(.primary))
        .accessibilityHidden(true)
      Text(lock.locked ? "MyAgents bloqueado" : "MyAgents").appFont(.title, weight: .semibold).foregroundStyle(theme.color(.textStrong))
      Text(message).appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
        .multilineTextAlignment(.center).frame(maxWidth: 320)
        .accessibilityIdentifier("app-lock-message")
      if lock.locked {
        Button(lock.phase == .locked ? "Desbloquear com Face ID" : "Tentar novamente") {
          Task { await lock.unlock() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(lock.prompting || lock.phase == .checking)
        .opacity(lock.phase == .checking ? 0 : 1)
        .accessibilityIdentifier("app-lock-retry")
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.color(.background))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("app-lock")
    .environment(\.appTheme, theme)
    .preferredColorScheme(appearance.colorScheme)
    .tint(theme.color(.primary))
    #if DEBUG
    .overlay(alignment: .topLeading) {
      Text("\(AppLockFixture.prompts)")
        .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1).clipped()
        .allowsHitTesting(false).accessibilityIdentifier("app-lock-prompts")
    }
    #endif
  }

  private var message: String {
    switch lock.phase {
    // Open but covered: the scene is inactive, or a prompt (turning the lock off) is up.
    case .open: lock.prompting ? "Confirmando o Face ID…" : ""
    case .locked: "Use o Face ID para abrir o app."
    case .checking: "Confirmando o Face ID…"
    case .failed(let failure): failure.message
    }
  }
}

#if DEBUG
/// `-OpenCodeAppLockFixture success,cancel,…` answers each Face ID prompt in turn (after
/// `-OpenCodeAppLockFixtureDelay` seconds, 0.3 by default; the last answer repeats), without LocalAuthentication.
/// `-OpenCodeAppLockFixtureUnavailable notEnrolled|unavailable|lockout` makes Face ID unavailable. UI tests only.
@MainActor @Observable final class AppLockFixture: BiometricAuthenticator {
  static var prompts: Int { (authenticator as? AppLockFixture)?.count ?? 0 }
  static let authenticator: (any BiometricAuthenticator)? = {
    let arguments = ProcessInfo.processInfo.arguments
    func value(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    guard let script = value("-OpenCodeAppLockFixture") else { return nil }
    return AppLockFixture(answers: script.split(separator: ",").map(String.init),
      delay: value("-OpenCodeAppLockFixtureDelay").flatMap(Double.init) ?? 0.3,
      unavailable: value("-OpenCodeAppLockFixtureUnavailable"))
  }()

  private(set) var count = 0
  private let answers: [String]
  private let delay: Double
  private let unavailable: String?
  private var cancelled = false

  private init(answers: [String], delay: Double, unavailable: String?) {
    self.answers = answers; self.delay = delay; self.unavailable = unavailable
  }

  func unavailability() -> BiometricFailure? {
    switch unavailable {
    case "notEnrolled": .notEnrolled
    case "unavailable": .unavailable
    case "lockout": .lockout
    default: nil
    }
  }

  func authenticate(reason: String) async -> BiometricFailure? {
    let answer = answers.isEmpty ? "success" : answers[min(count, answers.count - 1)]
    count += 1
    cancelled = false
    try? await Task.sleep(for: .seconds(delay))
    if cancelled { return .cancelled }
    return switch answer {
    case "success": nil
    case "cancel": .cancelled
    case "lockout": .lockout
    default: .notRecognized
    }
  }

  func cancel() { cancelled = true }
}
#endif
