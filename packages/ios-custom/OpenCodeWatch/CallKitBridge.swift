import AVFAudio
import CallKit
import Foundation

/// Outgoing CallKit call. TN3135: watchOS allows low-level networking to a VoIP app only during a CallKit call
/// (an `AVAudioSession` alone gets `ENETDOWN`), so audio and UDP start only after `didActivate`.
@MainActor final class CallKitBridge: NSObject, CXProviderDelegate {
  private let provider: CXProvider
  private let controller = CXCallController()
  private(set) var callUUID: UUID?
  private(set) var activated = false
  private(set) var log: [String] = []
  /// The system ended the call (call UI, another call, reset).
  var onEnded: ((String) -> Void)?
  /// Mute toggled here or in the system call UI.
  var onMuted: ((Bool) -> Void)?

  override init() {
    let configuration = CXProviderConfiguration()
    configuration.supportsVideo = false
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  func start() async throws {
    let uuid = UUID()
    callUUID = uuid
    activated = false
    log = []
    // No contactIdentifier: it must be a real CNContact ID (a made-up one coincided with a Carousel abort).
    let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: "sessao-mestra"))
    action.isVideo = false
    try await controller.request(CXTransaction(action: action))
    log.append("start.requested")
  }

  func waitForActivation(seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !activated, Date() < deadline, callUUID != nil {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return activated
  }

  func connected() {
    guard let callUUID else { return }
    provider.reportOutgoingCall(with: callUUID, connectedAt: Date())
  }

  func setMuted(_ muted: Bool) {
    guard let callUUID else { return }
    Task { try? await controller.request(CXTransaction(action: CXSetMutedCallAction(call: callUUID, muted: muted))) }
  }

  func end() {
    guard let callUUID else { return }
    self.callUUID = nil
    Task {
      do {
        try await controller.request(CXTransaction(action: CXEndCallAction(call: callUUID)))
      } catch {
        provider.reportCall(with: callUUID, endedAt: Date(), reason: .remoteEnded)
      }
    }
  }

  func fail() {
    guard let callUUID else { return }
    self.callUUID = nil
    provider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
  }

  nonisolated func providerDidReset(_ provider: CXProvider) {
    MainActor.assumeIsolated {
      log.append("reset")
      callUUID = nil
      onEnded?("callkit_reset")
    }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    // Configure (do not activate) the session; the system activates it and calls didActivate.
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    let update = CXCallUpdate()
    update.localizedCallerName = "Sessão mestra"
    update.hasVideo = false
    provider.reportCall(with: action.callUUID, updated: update)
    action.fulfill()
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    let muted = action.isMuted
    action.fulfill()
    MainActor.assumeIsolated { onMuted?(muted) }
  }

  nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    let id = action.callUUID
    action.fulfill()
    MainActor.assumeIsolated {
      guard callUUID == id else { return }
      callUUID = nil
      onEnded?("callkit_end")
    }
  }

  nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated {
      log.append("didActivate")
      activated = true
    }
  }

  nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    MainActor.assumeIsolated { activated = false }
  }
}
