import Foundation
import Observation
import OpenCodeKit
import WatchKit

/// One GPT Live call with the Sessão mestra: CallKit, then audio, then the gateway signalling and the UDP media
/// (the proven path), plus the 5 s heartbeat and the events long poll. Captions and progress come only from the
/// gateway; the media never crosses the Mac.
@MainActor @Observable final class VoiceCall {
  enum Phase: Equatable {
    case idle, connecting, live, failed(String)
  }

  private(set) var phase: Phase = .idle
  private(set) var timeline = WatchVoiceTimeline()
  private(set) var connectedAt: Date?
  private(set) var muted = false
  private(set) var inputLevel: Float = 0
  private(set) var outputLevel: Float = 0

  @ObservationIgnored private let callKit = CallKitBridge()
  @ObservationIgnored private var media: WatchRealtimeMediaSession?
  @ObservationIgnored private var client: WatchGatewayClient?
  @ObservationIgnored private var callID: String?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var attempt = UUID()
  @ObservationIgnored private let fixture: Bool

  init(fixture: Bool = false) {
    self.fixture = fixture
    callKit.onEnded = { [weak self] _ in self?.end(local: false) }
    callKit.onMuted = { [weak self] muted in self?.applyMute(muted) }
  }

  /// Fixture for captures: a live call with captions and progress, no audio or network.
  func showFixture() {
    phase = .live
    connectedAt = Date().addingTimeInterval(-134)
    inputLevel = 0.5
    outputLevel = 0.7
    var timeline = WatchVoiceTimeline()
    let json = """
      {"events":[{"seq":1,"at":0,"type":"caption","role":"user","text":"abre um PR com a correção","final":true},
       {"seq":2,"at":0,"type":"caption","role":"assistant","text":"certo, vou pedir pra sessão Live Activity...","final":false},
       {"seq":3,"at":0,"type":"master","state":"running","text":"Pedindo à sessão Live Activity"}],"next":3,"ended":false}
      """
    if let batch = try? JSONDecoder().decode(WatchVoiceEvents.self, from: Data(json.utf8)) { timeline.apply(batch) }
    self.timeline = timeline
  }

  func start(pairing: WatchPairing) {
    guard phase != .connecting, phase != .live else { return }
    let attempt = UUID()
    self.attempt = attempt
    timeline = WatchVoiceTimeline()
    connectedAt = nil
    muted = false
    phase = .connecting
    let client = WatchGatewayClient(pairing: pairing, version: WatchModel.version)
    self.client = client
    #if targetEnvironment(simulator)
      let plan = WatchRealtimeAudioIO.Plan.duplex  // The simulator has no CallKit and allows UDP anyway.
    #else
      let plan = WatchRealtimeAudioIO.Plan.external
    #endif
    let media = WatchRealtimeMediaSession(plan: plan) { [weak self] event in
      Task { @MainActor in self?.handle(event, attempt: attempt) }
    }
    self.media = media
    tasks.append(Task {
      do {
        media.setMuted(true)
        #if !targetEnvironment(simulator)
          try await callKit.start()
          guard await callKit.waitForActivation(seconds: 10) else { throw VoiceFailure("O áudio da chamada não iniciou.") }
        #endif
        try check(attempt)
        try await media.startAudio()
        try check(attempt)
        let offer = try await media.makeOffer()
        let call = try await client.startCall(sdp: offer, voiceID: pairing.voice.voiceID)
        try check(attempt)
        callID = call.callID
        startLoops(client: client, callID: call.callID, attempt: attempt)
        try await media.applyAnswer(call.sdp)
        try check(attempt)
        try await Task.sleep(for: .seconds(20))
        if phase == .connecting { throw VoiceFailure("A conexão de voz não completou.") }
      } catch is CancellationError {
      } catch {
        fail(error, attempt: attempt)
      }
    })
  }

  func toggleMute() {
    if fixture {
      muted.toggle()
      return
    }
    applyMute(!muted)
    callKit.setMuted(muted)
  }

  /// Ends from the app; the system call UI ends through CallKit (`onEnded`).
  func end() { end(local: true) }

  func retry(pairing: WatchPairing?) {
    phase = .idle
    if let pairing { start(pairing: pairing) }
  }

  func dismissFailure() { if case .failed = phase { phase = .idle } }

  // MARK: Private

  private func applyMute(_ muted: Bool) {
    self.muted = muted
    if phase == .live { media?.setMuted(muted) }
  }

  private func startLoops(client: WatchGatewayClient, callID: String, attempt: UUID) {
    tasks.append(Task {
      while !Task.isCancelled, self.attempt == attempt {
        let packets = media?.counters.value.withLock { $0 } ?? (sent: 0, received: 0)
        try? await client.heartbeat(callID, sent: packets.sent, received: packets.received)
        try? await Task.sleep(for: .seconds(5))
      }
    })
    tasks.append(Task {
      var failures = 0
      while !Task.isCancelled, self.attempt == attempt {
        do {
          let batch = try await client.events(callID, after: timeline.next)
          failures = 0
          guard self.attempt == attempt else { return }
          timeline.apply(batch)
          if let error = timeline.error, phase == .connecting { fail(VoiceFailure(error), attempt: attempt) }
          if timeline.ended != nil {
            end(local: false)
            return
          }
        } catch is CancellationError {
          return
        } catch {
          failures += 1
          try? await Task.sleep(for: .seconds(min(Double(failures), 5)))
        }
      }
    })
  }

  private func handle(_ event: WatchRealtimeSessionEvent, attempt: UUID) {
    guard self.attempt == attempt else { return }
    switch event {
    case .connected:
      guard connectedAt == nil else { return }
      connectedAt = Date()
      phase = .live
      media?.setMuted(muted)
      callKit.connected()
      WKInterfaceDevice.current().play(.start)
    case .inputLevel(let level): inputLevel = level
    case .outputLevel(let level): outputLevel = level
    case .ended(let failure):
      let message = switch failure.kind {
      case .network: "A conexão de voz caiu."
      case .audio: "O áudio da chamada falhou."
      case .sessionEnded: "A chamada terminou."
      case .protocolError: "A conexão segura de voz falhou."
      }
      fail(VoiceFailure(message, detail: failure.message), attempt: attempt)
    }
  }

  private func check(_ attempt: UUID) throws {
    try Task.checkCancellation()
    guard self.attempt == attempt else { throw CancellationError() }
  }

  private func fail(_ error: any Error, attempt: UUID) {
    guard self.attempt == attempt, phase == .connecting || phase == .live else { return }
    let message = (error as? VoiceFailure)?.message ?? (error as? WatchGatewayError)?.message
      ?? "A chamada de voz falhou."
    reportDiagnostics(stage: phase == .live ? "media" : "connect",
      message: (error as? VoiceFailure)?.detail ?? message)
    callKit.fail()
    teardown()
    phase = .failed(message)
    WKInterfaceDevice.current().play(.failure)
  }

  private func end(local: Bool) {
    guard phase == .connecting || phase == .live else { return }
    if local { callKit.end() }
    teardown()
    phase = .idle
    WKInterfaceDevice.current().play(.stop)
  }

  /// Media and audio close first; then the gateway releases the call (and its lease).
  private func teardown() {
    attempt = UUID()
    tasks.forEach { $0.cancel() }
    tasks = []
    inputLevel = 0
    outputLevel = 0
    let media = self.media
    let client = self.client
    let callID = self.callID
    self.media = nil
    self.callID = nil
    Task {
      await media?.stop()
      if let client, let callID { try? await client.endCall(callID) }
    }
  }

  private func reportDiagnostics(stage: String, message: String) {
    guard let client else { return }
    var events: [[String: String]] = [["type": "voice.failed", "stage": stage, "message": message]]
    let lines = media?.transportDiagnostics ?? []
    if !lines.isEmpty { events.append(["type": "voice.transport", "flows": lines.joined(separator: "; ")]) }
    if let audio = media?.audioFlow { events.append(["type": "voice.audio", "plan": audio.categoryNote]) }
    Task { try? await client.diagnostics(events) }
  }
}

struct VoiceFailure: Error {
  let message: String
  /// Engine detail (English) for diagnostics only.
  let detail: String?
  init(_ message: String, detail: String? = nil) {
    self.message = message
    self.detail = detail
  }
}
