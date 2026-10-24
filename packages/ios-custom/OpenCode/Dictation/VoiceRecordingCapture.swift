import AVFoundation
import Foundation
import OpenCodeKit

@MainActor protocol VoiceRecordingCapture: AnyObject {
  func authorize() async -> Bool
  func start(at file: URL) async throws
  var elapsed: TimeInterval { get }
  var level: Float { get }
  func pause()
  func resume() async throws
  func stop()
}

/// AVAudioSession activation and deactivation block the caller (Apple's "Hang Risk").
/// One serial queue keeps them off the main thread and in the order they were requested,
/// so a deactivation queued by stop/pause always precedes the next activation.
enum DictationAudioSession {
  private static let queue = DispatchQueue(label: "br.com.alexandrem.opencode.dictation-audio", qos: .userInitiated)
  /// `AVAudioRecorder.record()` and `AVAudioPlayer.play()` activate the session again
  /// internally, so `start` runs here too, right after the activation.
  static func activate(_ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions = [],
                       then start: (@Sendable () -> Bool)? = nil) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(category, mode: .default, options: options)
          if category == .playAndRecord { try session.setAllowHapticsAndSystemSoundsDuringRecording(true) }
          try session.setActive(true)
          if let start, !start() { throw TranscriptionError.integrity }
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  static func deactivate() {
    queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
  }
  /// Waits for an activation in flight; only used when stop races a start or resume.
  static func drain() { queue.sync {} }
}

/// Hands a recorder or player to the audio queue while the main actor awaits its start.
struct QueuedAudio<Value>: @unchecked Sendable { let value: Value }

/// Continuous PCM, including pause/resume on the same recorder, as in Abacato.
@MainActor final class MicrophoneVoiceCapture: VoiceRecordingCapture {
  private var recorder: AVAudioRecorder?
  private var ownsSession = false
  private var activating = false
  // stop() during an activation invalidates it, so a late activation reports cancellation.
  private var attempt = UUID()
  func authorize() async -> Bool { await AVAudioApplication.requestRecordPermission() }
  func start(at file: URL) async throws {
    do {
      let recorder = try AVAudioRecorder(url: file, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      ])
      recorder.isMeteringEnabled = true
      self.recorder = recorder
      try await record(recorder)
    } catch { stop(); throw error }
  }
  private func record(_ recorder: AVAudioRecorder) async throws {
    let current = UUID()
    attempt = current
    ownsSession = true
    activating = true
    defer { activating = false }
    let queued = QueuedAudio(value: recorder)
    try await DictationAudioSession.activate(.playAndRecord, options: [.defaultToSpeaker]) { queued.value.record() }
    guard attempt == current else { throw CancellationError() }
  }
  var elapsed: TimeInterval { recorder?.currentTime ?? 0 }
  var level: Float {
    recorder?.updateMeters()
    return Self.displayLevel(decibels: recorder?.averagePower(forChannel: 0) ?? -160)
  }
  nonisolated static func displayLevel(decibels: Float) -> Float { min(1, max(0, (decibels + 50) / 50)) }
  func pause() { recorder?.pause(); releaseSession() }
  func resume() async throws {
    guard let recorder else { throw TranscriptionError.integrity }
    do { try await record(recorder) } catch { releaseSession(); throw error }
  }
  func stop() {
    // A recorder whose start is still queued must not begin recording after this stop.
    if activating { DictationAudioSession.drain() }
    recorder?.stop(); recorder = nil; releaseSession()
  }
  private func releaseSession() {
    attempt = UUID()
    guard ownsSession else { return }
    DictationAudioSession.deactivate()
    ownsSession = false
  }
}
