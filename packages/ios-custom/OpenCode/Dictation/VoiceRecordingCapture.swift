import AVFoundation
import Foundation
import OpenCodeKit
import os

@MainActor protocol VoiceRecordingCapture: AnyObject {
  /// The microphone is already allowed: recording starts at the touch, with no system prompt to take the gesture.
  var authorized: Bool { get }
  func authorize() async -> Bool
  func start(at file: URL) async throws
  var elapsed: TimeInterval { get }
  var level: Float { get }
  func pause()
  func resume() async throws
  func stop()
}

extension VoiceRecordingCapture {
  var authorized: Bool { false }
}

/// AVAudioSession activation and deactivation block the caller (Apple's "Hang Risk").
/// One serial queue keeps them off the main thread and in the order they were requested,
/// so a deactivation queued by stop/pause always precedes the next activation.
enum DictationAudioSession {
  private static let queue = DispatchQueue(label: "br.com.alexandrem.opencode.dictation-audio", qos: .userInitiated)
  #if os(macOS)
  enum Category { case playAndRecord, playback }
  enum Mode { case `default`, spokenAudio }
  struct Options: OptionSet, Sendable {
    let rawValue: Int
    static let defaultToSpeaker = Options(rawValue: 1)
  }
  // Core Audio uses the system devices. Keep the same serial executor without an AVAudioSession on macOS.
  static func activate<Value: Sendable>(_ category: Category, mode: Mode = .default, options: Options = [],
    then start: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try start() }) }
    }
  }
  static func deactivate() {}
  #else
  /// `AVAudioRecorder.record()` and `AVAudioPlayer.play()` activate the session again
  /// internally, so `start` runs here too, right after the activation. A failure deactivates.
  static func activate<Value: Sendable>(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode = .default,
                                        options: AVAudioSession.CategoryOptions = [],
                                        then start: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        let session = AVAudioSession.sharedInstance()
        do {
          try session.setCategory(category, mode: mode, options: options)
          if category == .playAndRecord { try session.setAllowHapticsAndSystemSoundsDuringRecording(true) }
          try session.setActive(true)
          continuation.resume(returning: try start())
        } catch {
          try? session.setActive(false, options: .notifyOthersOnDeactivation)
          continuation.resume(throwing: error)
        }
      }
    }
  }
  /// Any other session change, in the same order as activations and deactivations, off the main thread.
  static func perform(_ change: @escaping @Sendable (AVAudioSession) -> Void) async {
    await withCheckedContinuation { continuation in
      queue.async {
        change(AVAudioSession.sharedInstance())
        continuation.resume()
      }
    }
  }
  static func deactivate() {
    queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
  }
  #endif
}

/// Hands a recorder or player between the audio queue and the main actor.
struct QueuedAudio<Value>: @unchecked Sendable { let value: Value }

#if os(macOS)
// The Mac records from a chosen input device: MicrophoneVoiceCapture in OpenCodeMac/MacMicrophone.swift.
#else
/// Continuous PCM, including pause/resume on the same recorder, as in Abacato.
@MainActor final class MicrophoneVoiceCapture: VoiceRecordingCapture {
  private var recorder: AVAudioRecorder?
  private var ownsSession = false
  /// stop() advances it without waiting for an activation in flight. The audio queue checks it under the lock right
  /// before recording, so a stopped opening never records and stop() waits at most for that `record()` call.
  private let epoch = OSAllocatedUnfairLock(initialState: 0)
  var authorized: Bool { AVAudioApplication.shared.recordPermission == .granted }
  func authorize() async -> Bool { authorized ? true : await AVAudioApplication.requestRecordPermission() }
  func start(at file: URL) async throws {
    let epoch = epoch, ticket = epoch.withLock { $0 }
    let opened = try await DictationAudioSession.activate(.playAndRecord, options: [.defaultToSpeaker]) {
      try epoch.withLock { current in
        guard current == ticket else { throw CancellationError() }
        let recorder = try AVAudioRecorder(url: file, settings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.record() else { recorder.stop(); throw TranscriptionError.integrity }
        return QueuedAudio(value: recorder)
      }
    }
    guard epoch.withLock({ $0 }) == ticket else {
      // stop() came after this opening began recording: none of it may remain or look like pending audio.
      opened.value.stop()
      try? FileManager.default.removeItem(at: file)
      DictationAudioSession.deactivate()
      throw CancellationError()
    }
    recorder = opened.value
    ownsSession = true
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
    let epoch = epoch, ticket = epoch.withLock { $0 }, queued = QueuedAudio(value: recorder)
    try await DictationAudioSession.activate(.playAndRecord, options: [.defaultToSpeaker]) {
      try epoch.withLock { current in
        guard current == ticket else { throw CancellationError() }
        guard queued.value.record() else { throw TranscriptionError.integrity }
      }
    }
    // stop() after the recorder resumed already stopped it; only the session is left to release.
    guard epoch.withLock({ $0 }) == ticket else { DictationAudioSession.deactivate(); throw CancellationError() }
    ownsSession = true
  }
  func stop() {
    epoch.withLock { $0 += 1 }
    recorder?.stop(); recorder = nil; releaseSession()
  }
  private func releaseSession() {
    guard ownsSession else { return }
    DictationAudioSession.deactivate()
    ownsSession = false
  }
}
#endif
