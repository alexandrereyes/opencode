import Foundation

/// How the file viewer's video player treats the shared audio session.
///
/// AVPlayer activates the app's session to play, and every category the app leaves behind (the default solo
/// ambient, read-aloud's playback, dictation's play-and-record) silences other apps when activated. A video with
/// no audio track has nothing to play, so it uses a mixable ambient category and leaves other apps' audio alone.
/// A video with an audio track, even a silent one (finding silence would mean decoding it), keeps the normal
/// player behaviour. While the app's own audio is active (a voice call, a reading) the session is left as it is.
public enum VideoAudioPolicy: Sendable, Equatable {
  case mixWithOthers
  case unchanged

  public static func decide(hasAudioTrack: Bool, appAudioActive: Bool) -> Self {
    !hasAudioTrack && !appAudioActive ? .mixWithOthers : .unchanged
  }

  /// Leaving the video hands the audio back to other apps, unless the app's own audio still needs the session.
  public static func deactivatesOnExit(appAudioActive: Bool) -> Bool { !appAudioActive }
}
