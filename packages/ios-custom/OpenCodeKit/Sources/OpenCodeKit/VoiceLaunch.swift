import Foundation

/// Why an external start (Action button, Control, App Shortcut) has to bring the app forward.
public enum VoiceLaunchReason: String, Sendable {
  /// iOS only presents the microphone prompt, or the Settings hint, from a visible app.
  case microphonePermission
  /// The call would have no Live Activity, and background recording requires one.
  case liveActivitiesDisabled
  /// The system refused to start the Live Activity from the background.
  case liveActivityRejected
  /// No paired server or readable credentials; the app explains and offers a retry.
  case serverUnavailable
}

public enum VoiceLaunchPlan: Equatable, Sendable {
  /// A call already exists (or is closing): keep it as is and only acknowledge the press.
  case acknowledge
  /// Start the call. `foreground` names why the app must come forward first; nil keeps it where it is.
  case start(foreground: VoiceLaunchReason?)
}

public enum VoiceMicrophoneAccess: Sendable { case granted, undetermined, denied }

public enum VoiceLaunch {
  /// Pure decision for an external start request; the app performs the side effects.
  public static func plan(phase: VoicePhase, busy: Bool, foreground: Bool,
    microphone: VoiceMicrophoneAccess, activitiesEnabled: Bool) -> VoiceLaunchPlan {
    if busy || (phase != .idle && phase != .failed) { return .acknowledge }
    if foreground { return .start(foreground: nil) }
    if microphone != .granted { return .start(foreground: .microphonePermission) }
    if !activitiesEnabled { return .start(foreground: .liveActivitiesDisabled) }
    return .start(foreground: nil)
  }
}
