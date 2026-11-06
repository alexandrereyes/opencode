import ActivityKit
import AppIntents
import OpenCodeKit
import SwiftUI

/// The composer dictation's Live Activity (Lock Screen, banner and Dynamic Island), ported from Abacato V2's
/// `VoiceRecordingActivityAttributes`. It only shows the recording and carries Parar: the microphone stays alive
/// through the app's audio session and its background audio mode, never through the activity. Separate from the
/// GPT Live call's `VoiceActivityAttributes`. Only an opaque id and the destination's title, never the text.
struct DictationActivityAttributes: ActivityAttributes {
  enum Phase: String, Codable, Hashable, Sendable {
    case recording
    /// Paused by the user or the system (an interruption, the route, another call).
    case paused
    /// Stopped: the audio waits for the transcription, which runs with the app open.
    case saved
    /// Transcribing or "Ajustando texto…".
    case transcribing
  }

  struct ContentState: Codable, Hashable, Sendable {
    var phase: Phase
    /// Where the text will go ("Nova sessão", the conversation's title); nil: "Ditado".
    var name: String?
    /// The timer's base while recording (now minus the recorded time); nil otherwise.
    var started: Date?
    /// The recorded time, in seconds, when not recording.
    var elapsed: TimeInterval?
    var colors: [String: [Double]]
    func color(_ role: ThemeRole) -> Color {
      let value = colors[String(role.rawValue)] ?? [0, 0, 0, 1]
      return Color(.sRGB, red: value[0], green: value[1], blue: value[2], opacity: value[3])
    }
  }

  let id: String
}

/// What the activity and the in-app strip say, one place for both and for the tests.
enum DictationActivityText {
  struct Rendered: Equatable, Sendable {
    var title: String
    var body: String?
    /// The system timer runs.
    var timer: Bool
    /// Parar is offered.
    var stop: Bool
  }

  static let stop = "Parar gravação"
  static func recording(_ name: String?) -> String { name.map { "Gravando para \($0)" } ?? "Gravando ditado" }
  static func paused(_ time: String) -> String { "Gravação pausada · \(time)" }
  static func saved(_ time: String) -> String { "Áudio salvo · \(time)" }
  static let savedBody = "Abra o MyAgents para transcrever"
  static let transcribing = "Transcrevendo ditado…"
  /// The stale `recording` (`staleDate` passed: the app stopped renewing it).
  static let staleTitle = "A gravação parou"
  static let staleBody = "Abra o MyAgents para revisar o áudio."

  /// `m:ss` with unbounded minutes ("0:04", "61:05").
  static func time(_ seconds: TimeInterval) -> String {
    let total = seconds.isFinite ? max(0, Int(seconds)) : 0, rest = total % 60
    return "\(total / 60):\(rest < 10 ? "0" : "")\(rest)"
  }

  static func render(_ state: DictationActivityAttributes.ContentState, stale: Bool) -> Rendered {
    switch state.phase {
    case .recording where stale: Rendered(title: staleTitle, body: staleBody, timer: false, stop: false)
    case .recording: Rendered(title: recording(state.name), body: nil, timer: true, stop: true)
    case .paused: Rendered(title: paused(time(state.elapsed ?? 0)), body: state.name, timer: false, stop: false)
    case .saved: Rendered(title: saved(time(state.elapsed ?? 0)), body: savedBody, timer: false, stop: false)
    case .transcribing: Rendered(title: transcribing, body: state.name, timer: false, stop: false)
    }
  }

  /// A tap on the activity opens the dictation's own composer.
  static let url = URL(string: "br.com.alexandrem.opencode://dictation")!
}

/// The process's dictation, as `VoiceActivityRouter` is the call's: the app sets the handler; a stale id does nothing.
@MainActor enum DictationActivityRouter {
  static var id: String?
  static var handler: (() -> Void)?
  static func stop(id: String) {
    guard self.id == id else { return }
    handler?()
  }
}

/// "Parar gravação" on the Lock Screen and in the Dynamic Island: the recording stops and keeps its audio for the
/// transcription into the composer it started in. Runs in the app's process, without opening it.
struct StopDictationIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Parar gravação"
  static let openAppWhenRun = false
  @Parameter(title: "Ditado") var id: String
  init() {}
  init(id: String) { self.id = id }
  func perform() async throws -> some IntentResult {
    await DictationActivityRouter.stop(id: id)
    return .result()
  }
}
