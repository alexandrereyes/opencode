import AppIntents
import OpenCodeKit

/// Implemented by the app process; the widget extension only references the intent type.
@MainActor protocol VoiceLaunching: AnyObject {
  func plan(foreground: Bool) async -> VoiceLaunchPlan
  /// Starts the call and waits until it is ready to listen or has failed. A background start that
  /// cannot proceed is undone and names why the app has to come forward; nil means it was handled.
  func start(background: Bool) async -> VoiceLaunchReason?
  func acknowledge()
}

@MainActor enum VoiceLaunchRouter {
  static var launcher: (any VoiceLaunching)?
}

/// Starts a GPT Live call with the Sessão mestra from the Action button, Control Center, the Lock
/// Screen or Shortcuts. It prefers the background, showing only the existing Live Activity, and
/// brings the app forward when iOS needs it (microphone prompt, Live Activities off or refused).
struct StartVoiceIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Conversar com a Sessão mestra"
  static let description = IntentDescription("Inicia a conversa por voz com a Sessão mestra sem abrir o OpenCode.")
  // The call can operate Alexandre's Mac, so a locked iPhone must be unlocked first.
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
  // Audio, the Live Activity and the call state live in the app process, never in the widget extension.
  static let allowedExecutionTargets: IntentExecutionTargets = .main

  @MainActor func perform() async throws -> some IntentResult {
    guard let launcher = VoiceLaunchRouter.launcher else { return .result() }
    let mode = systemContext.currentMode
    let foreground = mode == .foreground
    switch await launcher.plan(foreground: foreground) {
    case .acknowledge:
      launcher.acknowledge()
    case .start(foreground: nil):
      guard let reason = await launcher.start(background: !foreground) else { break }
      try await bringForward(mode, reason: reason)
      _ = await launcher.start(background: false)
    case .start(foreground: let reason?):
      try await bringForward(mode, reason: reason)
      _ = await launcher.start(background: false)
    }
    return .result()
  }

  @MainActor private func bringForward(_ mode: IntentModes.Current, reason: VoiceLaunchReason) async throws {
    VoiceLaunchLog.record("launch-foreground reason=\(reason.rawValue)")
    guard mode.canContinueInForeground else { throw VoiceLaunchError.needsApp }
    try await continueInForeground(nil, alwaysConfirm: false)
  }
}

enum VoiceLaunchError: Error, CustomLocalizedStringResourceConvertible {
  case needsApp
  var localizedStringResource: LocalizedStringResource {
    "Abra o OpenCode para conversar por voz: o iPhone precisa da permissão do microfone ou das Atividades ao Vivo."
  }
}
