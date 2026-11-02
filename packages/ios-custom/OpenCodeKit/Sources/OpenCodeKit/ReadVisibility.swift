import Foundation

/// When a shown conversation may acknowledge its answers on its own (`POST /api/session/{id}/view`): only while its
/// user can actually see it. A conversation left open behind another app, in a hidden or minimized window, or with
/// the screen asleep or locked keeps its answers unread for Sessões, the Live Activity and the other clients.
/// Marking a session read by hand is not gated.
public enum ReadVisibility {
  /// The Mac: the app is active, the window is on screen (visible, not minimized, not fully covered) and the user's
  /// session is awake (screens on, unlocked, the active console session).
  public static func desktop(
    appActive: Bool, windowVisible: Bool, minimized: Bool, occluded: Bool, systemAwake: Bool
  ) -> Bool {
    appActive && windowVisible && !minimized && !occluded && systemAwake
  }

  /// The iPhone: the conversation is the screen on top of its stack and the scene is in the foreground. A locked
  /// phone or the app switcher makes the scene inactive or backgrounded.
  public static func phone(screenVisible: Bool, sceneActive: Bool) -> Bool {
    screenVisible && sceneActive
  }
}
