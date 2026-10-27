import Foundation
import Observation
import OpenCodeKit
import WatchConnectivity

/// Sends the watch pairing over WatchConnectivity (`transferUserInfo`, plus `updateApplicationContext` so a
/// reinstalled watch app re-syncs). The iPhone keeps no watch credential.
@MainActor @Observable final class PhoneWatchLink {
  static let shared = PhoneWatchLink()

  private(set) var activated = false
  private(set) var paired = false
  private(set) var installed = false

  @ObservationIgnored private var delegate: Delegate?

  func activate() {
    guard WCSession.isSupported(), delegate == nil else { return }
    let delegate = Delegate { [weak self] state in self?.update(state) }
    self.delegate = delegate
    WCSession.default.delegate = delegate
    WCSession.default.activate()
  }

  func send(_ pairing: WatchPairing) async throws {
    activate()
    // Activation is asynchronous; transfers before it completes are rejected.
    for _ in 0..<40 where !activated { try await Task.sleep(for: .milliseconds(100)) }
    guard activated else { throw PhoneWatchError.inactive }
    guard paired else { throw PhoneWatchError.notPaired }
    guard installed else { throw PhoneWatchError.notInstalled }
    let payload = try pairing.transferPayload()
    WCSession.default.transferUserInfo(payload)
    try WCSession.default.updateApplicationContext(payload)
  }

  /// Tells the watch whose device was removed; it clears its Keychain only if the ID is its own.
  func revoked(deviceID: String) {
    guard activated, paired, installed else { return }
    let payload = [WatchPairing.revokedKey: deviceID]
    WCSession.default.transferUserInfo(payload)
    try? WCSession.default.updateApplicationContext(payload)
  }

  private func update(_ state: Delegate.State) {
    activated = state.activated
    paired = state.paired
    installed = state.installed
  }

  private final class Delegate: NSObject, WCSessionDelegate {
    struct State: Sendable {
      let activated: Bool
      let paired: Bool
      let installed: Bool
    }

    private let report: @MainActor @Sendable (State) -> Void
    init(report: @escaping @MainActor @Sendable (State) -> Void) { self.report = report }

    private func publish(_ session: WCSession) {
      let state = State(activated: session.activationState == .activated, paired: session.isPaired,
        installed: session.isWatchAppInstalled)
      let report = report
      Task { @MainActor in report(state) }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: (any Error)?) {
      publish(session)
    }
    func sessionWatchStateDidChange(_ session: WCSession) { publish(session) }
    func sessionDidBecomeInactive(_ session: WCSession) { publish(session) }
    func sessionDidDeactivate(_ session: WCSession) {
      // Switching watches: reactivate for the newly paired one.
      session.activate()
    }
  }
}

enum PhoneWatchError: LocalizedError {
  case inactive, notPaired, notInstalled
  var errorDescription: String? {
    switch self {
    case .inactive: "Não foi possível falar com o Apple Watch. Tente de novo."
    case .notPaired: "Nenhum Apple Watch está pareado com este iPhone."
    case .notInstalled: "Instale o OpenCode no relógio pelo app Watch e tente de novo."
    }
  }
}
