import Foundation

/// How the file viewer's player (video and audio files) treats the shared audio session.
///
/// AVPlayer plays with whatever category the app left behind, and the app leaves several: the default solo
/// ambient, read-aloud's playback, and dictation's or the voice call's play-and-record with `.defaultToSpeaker` and
/// no A2DP, which sends a movie to the iPhone's speaker even with AirPods connected and hides them from the route
/// menu. So a file with sound sets Apple's category for media playback, `.playback` (`.moviePlayback` for a video):
/// it follows the route the user chose (AirPods, Bluetooth A2DP, AirPlay, the speaker) and the player's own route
/// button lists those outputs. A video with no audio track has nothing to play, so it uses a mixable ambient category
/// and leaves other apps' audio alone. A track that exists but is silent counts as sound (finding silence would mean
/// decoding it). While the app's own audio is active (a voice call, a reading) the session is left as it is.
public enum VideoAudioPolicy: Sendable, Equatable {
  case mixWithOthers
  /// `.playback`; `movie` picks the `.moviePlayback` mode, otherwise `.default` (an audio file).
  case playback(movie: Bool)
  case unchanged

  public static func decide(hasAudioTrack: Bool, hasVideoTrack: Bool = true, appAudioActive: Bool) -> Self {
    if appAudioActive { return .unchanged }
    return hasAudioTrack ? .playback(movie: hasVideoTrack) : .mixWithOthers
  }

  /// Leaving the player hands the audio back to other apps, unless the app's own audio still needs the session.
  public static func deactivatesOnExit(appAudioActive: Bool) -> Bool { !appAudioActive }
}
