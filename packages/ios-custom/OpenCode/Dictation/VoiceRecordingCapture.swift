import AVFoundation
import Foundation
#if os(iOS)
import MediaPlayer
#endif
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
          DictationAudioTrace.record("activate", detail: DictationAudioTrace.state(session))
          continuation.resume(returning: try start())
        } catch {
          DictationAudioTrace.record("activate", error: error, detail: DictationAudioTrace.state(session))
          release(session)
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
    queue.async { release(AVAudioSession.sharedInstance()) }
  }
  /// Gives the other apps' audio back; a failure is recorded, never swallowed. Whether their audio came back shows
  /// one and three seconds later, from the queue (`isOtherAudioPlaying`).
  private static func release(_ session: AVAudioSession) {
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      DictationAudioTrace.record("deactivate", detail: DictationAudioTrace.state(session))
    } catch {
      DictationAudioTrace.record("deactivate", error: error, detail: DictationAudioTrace.state(session))
    }
    for delay in [1, 3] {
      queue.asyncAfter(deadline: .now() + .seconds(delay)) {
        DictationAudioTrace.record("after-deactivate-\(delay)s", detail: DictationAudioTrace.others(session))
      }
    }
  }
  #endif
}

/// What the dictation did with the shared audio session, in order, for a physical test without a debugger: the
/// unified log (subsystem `br.com.alexandrem.opencode`, category `dictation-audio`) and the last events in memory.
/// Only session state, routes' port types, enums and error codes: never speech, file names or account data.
enum DictationAudioTrace {
  struct Event: Sendable, Equatable {
    let name: String
    /// The `NSError` code of a failed session call (`AVAudioSession.ErrorCode`), nil when it succeeded.
    let error: Int?
  }
  private static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "dictation-audio")
  private static let recent = OSAllocatedUnfairLock(initialState: [Event]())
  static var events: [Event] { recent.withLock { $0 } }
  static func record(_ name: String, error: (any Error)? = nil, detail: String = "") {
    let failure = error.map { $0 as NSError }
    recent.withLock { events in
      events.append(Event(name: name, error: failure?.code))
      if events.count > 64 { events.removeFirst(events.count - 64) }
    }
    if let failure {
      log.error("\(name, privacy: .public) failed \(failure.domain, privacy: .public) \(failure.code) \(detail, privacy: .public)")
    } else {
      log.notice("\(name, privacy: .public) \(detail, privacy: .public)")
    }
  }
  #if os(iOS)
  static func state(_ session: AVAudioSession) -> String {
    let ports = { (ports: [AVAudioSessionPortDescription]) in ports.map(\.portType.rawValue).joined(separator: ",") }
    return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) options=\(session.categoryOptions.rawValue) "
      + "in=\(ports(session.currentRoute.inputs)) out=\(ports(session.currentRoute.outputs)) " + others(session)
  }
  static func others(_ session: AVAudioSession) -> String {
    "otherAudio=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint)"
  }
  /// Whether this app could take Now Playing from the music app when its non-mixable session activates: remote
  /// command handlers (only a reading registers them) and Now Playing info. `isEnabled` is true by default, so it
  /// says nothing.
  @MainActor static func nowPlaying() -> String {
    "remoteHandlers=\(ReadAloudPlayer.holdsRemoteCommands) info=\(MPNowPlayingInfoCenter.default().nowPlayingInfo != nil)"
  }
  @MainActor private static var observers: [any NSObjectProtocol] = []
  /// From the first dictation on, the session notifications the app receives (while dictating and after, when the
  /// other app's audio should come back), with their raw reasons.
  @MainActor static func watch() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    func watch(_ name: Notification.Name, _ label: String, _ keys: [String]) -> any NSObjectProtocol {
      center.addObserver(forName: name, object: nil, queue: nil) { note in
        record(label, detail: keys.map { "\($0)=\(note.userInfo?[$0].map { "\($0)" } ?? "-")" }.joined(separator: " "))
      }
    }
    observers = [
      watch(AVAudioSession.interruptionNotification, "interruption",
        [AVAudioSessionInterruptionTypeKey, AVAudioSessionInterruptionOptionKey, AVAudioSessionInterruptionReasonKey]),
      watch(AVAudioSession.routeChangeNotification, "route", [AVAudioSessionRouteChangeReasonKey]),
      watch(AVAudioSession.silenceSecondaryAudioHintNotification, "silence-hint", [AVAudioSessionSilenceSecondaryAudioHintTypeKey]),
    ]
  }
  #else
  @MainActor static func nowPlaying() -> String { "" }
  @MainActor static func watch() {}
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
