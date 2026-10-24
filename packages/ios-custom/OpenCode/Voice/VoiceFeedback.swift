import AudioToolbox
import UIKit

/// Call milestones felt without looking at the screen. UIKit generators only play in a visible app,
/// so a call started from the Action button or a Control uses the system vibration instead; the
/// transport allows haptics and system sounds while the microphone records.
@MainActor enum VoiceFeedback {
  static func ready() { play(.success) }
  static func failed() { play(.error) }
  static func lost() { play(.warning) }
  static func restored() { play(.success) }
  /// A press while a call is already running keeps that call and only acknowledges.
  static func alreadyActive() { play(.warning) }

  private static func play(_ kind: UINotificationFeedbackGenerator.FeedbackType) {
    if UIApplication.shared.applicationState == .active {
      UINotificationFeedbackGenerator().notificationOccurred(kind)
      return
    }
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
  }
}
