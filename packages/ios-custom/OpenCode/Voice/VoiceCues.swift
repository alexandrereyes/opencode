import AVFAudio
import Foundation
@preconcurrency import WebRTC

enum VoiceCue: Sendable { case lost, restored, failed }

@MainActor protocol VoiceCueing: AnyObject {
  /// `lost` starts a soft waiting tick that lasts until `restored`, `failed` or `stop`.
  func play(_ cue: VoiceCue)
  func stop()
}

/// Short tones and haptics for network loss, so no text is needed to follow a call in the pocket or the car.
/// While a call is rebuilt there is no WebRTC audio; the audible waiting tick holds the shared audio session
/// and keeps the background audio mode honest until the new call, the failure tone or the end.
@MainActor final class VoiceCuePlayer: VoiceCueing {
  private static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var observer: NSObjectProtocol?
  private var holding = false
  private var waiting = false
  private var finishing = false

  func play(_ cue: VoiceCue) {
    switch cue {
    case .lost:
      VoiceFeedback.lost()
      guard start() else { return }
      waiting = true; finishing = false
      schedule(Self.tone([(660, 0.12), (440, 0.18)]))
      schedule(Self.tone([(880, 0.05), (0, 2.95)], level: 0.08), options: .loops)
    case .restored:
      VoiceFeedback.restored()
      finish(Self.tone([(440, 0.1), (660, 0.14)]))
    case .failed:
      // No vibration here: the controller's fail() always follows and vibrates once.
      finish(Self.tone([(392, 0.18), (294, 0.32)]))
    }
  }

  /// Immediate release, except a final tone already scheduled finishes and releases itself.
  func stop() {
    guard !finishing else { return }
    release()
  }

  private func release() {
    waiting = false; finishing = false
    observer.map(NotificationCenter.default.removeObserver); observer = nil
    player?.stop(); engine?.stop(); player = nil; engine = nil
    guard holding else { return }
    let audio = RTCAudioSession.sharedInstance()
    audio.lockForConfiguration()
    try? audio.setActive(false)
    audio.unlockForConfiguration()
    holding = false
  }

  /// A final tone interrupts the waiting tick and releases the session once played.
  private func finish(_ buffer: AVAudioPCMBuffer) {
    guard waiting, let player else { release(); return }
    waiting = false; finishing = true
    player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.player === player, self.finishing else { return }
        self.release()
      }
    }
  }

  private func start() -> Bool {
    if engine != nil { return true }
    let audio = RTCAudioSession.sharedInstance()
    audio.lockForConfiguration()
    // The call already configured playAndRecord; this only adds an activation credit to the shared count.
    holding = (try? audio.setActive(true)) != nil
    audio.unlockForConfiguration()
    guard holding else { VoiceTransport.log.notice("phase=cue-unavailable"); return false }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    do {
      try engine.connectNode(player, to: engine.mainMixerNode, format: Self.format)
      try engine.start()
      try player.playAudio()
    } catch { VoiceTransport.log.notice("phase=cue-unavailable"); release(); return false }
    self.engine = engine; self.player = player
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
      queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.waiting, let engine = self.engine, let player = self.player else { return }
          // A route change stops the engine; resume the tick on the new route.
          player.stop()
          guard (try? engine.start()) != nil, (try? player.playAudio()) != nil else { return }
          self.schedule(Self.tone([(880, 0.05), (0, 2.95)], level: 0.08), options: .loops)
        }
      }
    return true
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, options: AVAudioPlayerNodeBufferOptions = []) {
    player?.scheduleBuffer(buffer, at: nil, options: options)
  }

  /// Sine segments with short fades; a zero frequency is silence.
  private static func tone(_ segments: [(Double, Double)], level: Float = 0.18) -> AVAudioPCMBuffer {
    let rate = format.sampleRate
    let total = AVAudioFrameCount(segments.reduce(0) { $0 + Int($1.1 * rate) })
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
    buffer.frameLength = total
    let samples = buffer.floatChannelData![0]
    var offset = 0
    for (frequency, duration) in segments {
      let count = Int(duration * rate)
      let fade = min(count / 4, Int(0.01 * rate))
      for index in 0..<count {
        let envelope = Float(min(1, Double(min(index, count - index)) / Double(max(1, fade))))
        samples[offset + index] = frequency == 0 ? 0
          : level * envelope * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
      }
      offset += count
    }
    return buffer
  }
}
