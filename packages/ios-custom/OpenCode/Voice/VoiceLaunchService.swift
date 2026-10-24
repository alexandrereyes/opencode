import ActivityKit
import AppIntents
import AVFAudio
import OpenCodeKit

/// Performs `StartVoiceIntent` in the app process. It resolves the shared runtime only when an
/// intent runs, so fixture launches never build it.
@MainActor final class AppVoiceLauncher: VoiceLaunching {
  func plan(foreground: Bool) async -> VoiceLaunchPlan {
    let voice = AppRuntime.shared.voice
    let microphone: VoiceMicrophoneAccess = switch AVAudioApplication.shared.recordPermission {
    case .granted: .granted
    case .denied: .denied
    default: .undetermined
    }
    VoiceLaunchLog.record("launch-request mode=\(foreground ? "foreground" : "background")")
    return VoiceLaunch.plan(phase: voice.state.phase, busy: voice.busy, foreground: foreground,
      microphone: microphone, activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled)
  }

  func start(background: Bool) async -> VoiceLaunchReason? {
    let runtime = AppRuntime.shared
    // Without a store the visible app already shows the credentials error and its retry.
    guard let store = await runtime.prepare() else { return background ? .serverUnavailable : nil }
    let voice = runtime.voice
    if voice.state.phase == .failed { await voice.end() }
    voice.start(sessions: store)
    // The Live Activity is requested synchronously by start(), before any audio activation.
    if background, !voice.liveActivityActive {
      await voice.end()
      return .liveActivityRejected
    }
    VoiceLaunchLog.record(background ? "launch-background" : "launch-app")
    runtime.keepSessionsRunning(store)
    await voice.settled(within: .seconds(30))
    return nil
  }

  func acknowledge() {
    VoiceLaunchLog.record("launch-acknowledged")
    VoiceFeedback.alreadyActive()
  }
}

struct OpenCodeShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: StartVoiceIntent(), phrases: [
      "Conversar com a Sessão mestra no \(.applicationName)",
      "Falar com a mestra no \(.applicationName)",
      "Iniciar voz no \(.applicationName)",
    ], shortTitle: "Falar com a mestra", systemImageName: "waveform")
  }
  static let shortcutTileColor: ShortcutTileColor = .orange
}
