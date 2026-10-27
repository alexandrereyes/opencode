import Foundation
import OpenCodeKit
import WatchConnectivity

/// Receives the pairing from the iPhone (`transferUserInfo`, re-synced with `updateApplicationContext`) and
/// hands it to the model, which keeps it in the Keychain. Nothing else crosses WatchConnectivity.
final class WatchLink: NSObject, WCSessionDelegate {
  private enum Message: Sendable {
    case pairing(WatchPairing)
    case revoked(String)
  }

  private let deliver: @MainActor @Sendable (Message) -> Void

  init(model: WatchModel) {
    deliver = { [weak model] message in
      switch message {
      case .pairing(let pairing): model?.apply(pairing)
      case .revoked(let deviceID): model?.revoke(deviceID: deviceID)
      }
    }
    super.init()
  }

  func activate() {
    guard WCSession.isSupported() else { return }
    WCSession.default.delegate = self
    WCSession.default.activate()
  }

  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
    guard state == .activated else { return }
    forward(session.receivedApplicationContext)
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { forward(userInfo) }

  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    forward(applicationContext)
  }

  private func forward(_ payload: [String: Any]) {
    let message: Message? =
      if let pairing = WatchPairing.from(payload: payload) { .pairing(pairing) }
      else if let deviceID = payload[WatchPairing.revokedKey] as? String { .revoked(deviceID) }
      else { nil }
    guard let message else { return }
    let deliver = deliver
    Task { @MainActor in deliver(message) }
  }
}
