import AVFAudio
import Foundation
import OpenCodeKit
import OSLog
@preconcurrency import WebRTC

enum VoiceTransportEvent: Sendable {
  /// `failed` says which part of the link went down, for the call's diagnostics.
  case connected, interrupted, resumed, disconnected, data(Data), failed(VoiceFailureReason)
}

protocol VoiceTransporting: AnyObject, Sendable {
  @MainActor func offer() async throws -> String
  @MainActor func answer(_ sdp: String) async throws
  @MainActor func send(_ data: Data) async throws
  @MainActor func mute(_ muted: Bool)
  @MainActor func resume()
  @MainActor func close() async
}

/// All native ownership, audio activation credits and callbacks run on this queue.
/// Only value types cross to MainActor; no WebRTC proxy escapes the executor.
final class VoiceTransport: NSObject, VoiceTransporting, @unchecked Sendable {
  static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "VoiceStartup")
  private static let native: Void = {
    // WebRTC follows the network itself (NWPathMonitor), so when Wi-Fi drops it can move the call to the candidate
    // pair it already has on cellular instead of waiting for the path to time out. Set once, before any factory.
    // Deprecated in M147, whose Objective-C factory has no other way to take field trials (Abacato does the same).
    RTCInitFieldTrialDictionary([kRTCFieldTrialUseNWPathMonitor: kRTCFieldTrialEnabledValue])
    RTCInitializeSSL()
  }()
  private let queue = DispatchQueue(label: "br.com.alexandrem.opencode.voice", qos: .userInitiated)
  private let event: @MainActor @Sendable (VoiceTransportEvent) -> Void
  private var factory: RTCPeerConnectionFactory?
  private var peer: RTCPeerConnection?
  private var microphone: RTCAudioTrack?
  private var channel: RTCDataChannel?
  private var pending: CheckedContinuation<String, any Error>?
  private var observers: [NSObjectProtocol] = []
  private var activations = 0
  private var iceConnected = false
  private var interrupted = false
  private var closed = false
  #if os(macOS)
  private var muted = false
  #endif

  @MainActor init(event: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) {
    self.event = event
    super.init()
  }

  @MainActor func offer() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { self.prepare(continuation) }
    }
  }

  private func prepare(_ continuation: CheckedContinuation<String, any Error>) {
    guard !closed else { continuation.resume(throwing: CancellationError()); return }
    pending = continuation
    do {
      _ = Self.native
      try activate()
      installObservers()
      #if os(macOS)
      // The input chosen in Ajustes → Voz, when it is not the default (Automático: the built-in microphone
      // instead of a Bluetooth headset's, which would drop the headset into the call profile).
      let custom = MacVoiceAudioDevice.needed
      Self.log.notice("phase=mac-audio-device custom=\(custom, privacy: .public)")
      factory = custom ? RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: MacVoiceAudioDevice())
        : RTCPeerConnectionFactory()
      #else
      factory = RTCPeerConnectionFactory()
      #endif
      let configuration = RTCConfiguration()
      configuration.sdpSemantics = .unifiedPlan
      configuration.bundlePolicy = .maxBundle
      configuration.tcpCandidatePolicy = .disabled
      configuration.disableLinkLocalNetworks = true
      configuration.continualGatheringPolicy = .gatherOnce
      let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      guard let factory, let peer = factory.peerConnection(with: configuration,
        constraints: constraints, delegate: self) else { throw VoiceWireError.invalidAnswer }
      self.peer = peer
      let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "opencode-voice")
      #if os(macOS)
      // Recovery can restore mute before the replacement track exists.
      track.isEnabled = !muted
      #endif
      microphone = track
      let transceiver = RTCRtpTransceiverInit()
      transceiver.direction = .sendRecv
      transceiver.streamIds = ["opencode-voice"]
      guard peer.addTransceiver(with: track, init: transceiver) != nil else { throw VoiceWireError.invalidAnswer }
      let settings = RTCDataChannelConfiguration()
      settings.isOrdered = true
      guard let channel = peer.dataChannel(forLabel: "oai-events", configuration: settings) else {
        throw VoiceWireError.invalidAnswer
      }
      self.channel = channel
      channel.delegate = self
      // Logged after the playAndRecord session is active and the microphone track exists.
      VoiceLaunchLog.record("offer-start")
      peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true",
        "OfferToReceiveVideo": "false"], optionalConstraints: nil)) { [weak self] offer, error in
        guard let self else { return }
        self.queue.async { [self] in
          guard !self.closed, let peer = self.peer else { return }
          guard error == nil, let offer else { self.failOffer(); return }
          peer.setLocalDescription(offer) { [weak self] error in
            guard let self else { return }
            self.queue.async {
              guard !self.closed else { return }
              if error != nil { self.failOffer(); return }
              self.finishGathering()
            }
          }
        }
      }
    } catch {
      pending?.resume(throwing: error); pending = nil
    }
  }

  private func finishGathering() {
    guard !closed, peer?.iceGatheringState == .complete, let sdp = peer?.localDescription?.sdp else { return }
    VoiceLaunchLog.record("offer-ready")
    pending?.resume(returning: sdp); pending = nil
  }
  private func failOffer() {
    pending?.resume(throwing: VoiceWireError.invalidAnswer); pending = nil
  }

  @MainActor func answer(_ sdp: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        guard !self.closed, let peer = self.peer else { continuation.resume(throwing: CancellationError()); return }
        peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    }
  }
  @MainActor func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        guard !self.closed, let channel = self.channel, channel.readyState == .open,
          channel.bufferedAmount < 65_536, channel.sendData(RTCDataBuffer(data: data, isBinary: false)) else {
          continuation.resume(throwing: VoiceWireError.invalidEvent); return
        }
        continuation.resume()
      }
    }
  }
  @MainActor func mute(_ muted: Bool) {
    queue.async {
      #if os(macOS)
      self.muted = muted
      #endif
      self.microphone?.isEnabled = !muted
    }
  }
  @MainActor func resume() { queue.async { self.reactivate() } }
  @MainActor func close() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.closed = true
        self.pending?.resume(throwing: CancellationError()); self.pending = nil
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }; self.observers = []
        self.channel?.delegate = nil; self.channel?.close(); self.channel = nil
        self.peer?.delegate = nil; self.peer?.close(); self.peer = nil
        self.microphone = nil; self.factory = nil
        #if os(iOS)
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        for _ in 0..<self.activations { try? audio.setActive(false) }
        self.activations = 0
        audio.unlockForConfiguration()
        #endif
        Self.log.notice("phase=transport-closed")
        continuation.resume()
      }
    }
  }
  private func emit(_ value: VoiceTransportEvent) {
    let event = event
    Task { @MainActor in event(value) }
  }
  private func activate() throws {
    #if os(iOS)
    let audio = RTCAudioSession.sharedInstance()
    guard activations == 0 || !audio.isActive else { return }
    audio.lockForConfiguration()
    defer { audio.unlockForConfiguration() }
    let configuration = RTCAudioSessionConfiguration.webRTC()
    configuration.category = AVAudioSession.Category.playAndRecord.rawValue
    configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
    configuration.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
    configuration.sampleRate = 48_000
    configuration.ioBufferDuration = 0.01
    RTCAudioSessionConfiguration.setWebRTC(configuration)
    audio.ignoresPreferredAttributeConfigurationErrors = true
    try audio.setConfiguration(configuration)
    // Lets VoiceFeedback vibrate when the call is ready or fails while the microphone records.
    try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    try audio.setActive(true)
    activations += 1
    #endif
    // macOS WebRTC owns Core Audio's default input/output and AEC. It follows device changes itself;
    // re-creating the peer or an AVAudioEngine here would tear down a healthy call on a headset change.
  }
  private func reactivate() {
    guard !closed, peer != nil else { return }
    do { try activate(); interrupted = false; emit(.resumed); updateConnected() }
    catch { interrupted = true; emit(.interrupted) }
  }
  private func updateConnected() {
    if iceConnected, channel?.readyState == .open, !interrupted { emit(.connected) }
  }
  private func installObservers() {
    #if os(iOS)
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
      object: nil, queue: nil) { [weak self] _ in
        guard let self else { return }
        self.queue.async {
          guard !self.closed else { return }
          self.interrupted = true; self.emit(.interrupted)
        }
      })
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.resumptionRecommendationNotification,
      object: nil, queue: nil) { [weak self] notification in
        let resume = (notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext)?.recommendation == .shouldResume
        guard let self, resume else { return }
        self.queue.async { self.reactivate() }
      })
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: nil) { [weak self] _ in
        guard let self else { return }
        self.queue.async { if !self.interrupted { self.reactivate() } }
      })
    observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil, queue: nil) { [weak self] _ in
        guard let self else { return }
        self.queue.async { if !self.closed { self.emit(.failed(.mediaReset)) } }
      })
    #endif
  }
}

extension VoiceTransport: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
  func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
  func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
  func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
  func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
  func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
  func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
  func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCIceGatheringState) {
    queue.async { if self.peer === peer, state == .complete { self.finishGathering() } }
  }
  func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCIceConnectionState) {
    queue.async {
      guard self.peer === peer, !self.closed else { return }
      if state == .connected || state == .completed { self.iceConnected = true; self.updateConnected() }
      if state == .disconnected { self.iceConnected = false; self.emit(.disconnected) }
      if state == .failed { self.emit(.failed(.iceFailed)) }
    }
  }
  func peerConnection(_ peer: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
    queue.async { if self.peer === peer, !self.closed, state == .failed { self.emit(.failed(.peerFailed)) } }
  }
  func dataChannelDidChangeState(_ channel: RTCDataChannel) {
    queue.async {
      guard self.channel === channel, !self.closed else { return }
      if channel.readyState == .closed || channel.readyState == .closing { self.emit(.failed(.dataChannelClosed)); return }
      self.updateConnected()
    }
  }
  func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    let data = buffer.data
    queue.async { if self.channel === channel, !self.closed { self.emit(.data(data)) } }
  }
}
