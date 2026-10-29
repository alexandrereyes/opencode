import AVFoundation
import OpenCodeKit

/// The shared audio session around one video in the file viewer (see `VideoAudioPolicy`).
@MainActor final class FileVideoAudio {
  private struct Saved: Sendable {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
  }
  private var saved: Saved?
  private var appAudioActive = false
  private(set) var policy: VideoAudioPolicy?

  static func hasAudioTrack(_ file: URL) async -> Bool {
    // Unknown counts as audio: the normal player behaviour is the safe default.
    (try? await AVURLAsset(url: file).loadTracks(withMediaType: .audio).isEmpty == false) ?? true
  }

  /// `appAudioActive` is the voice call; a reading is checked here.
  func prepare(_ file: URL, appAudioActive voice: Bool) async {
    let busy = voice || ReadAloudPlayer.isActive
    appAudioActive = busy
    let policy = VideoAudioPolicy.decide(hasAudioTrack: await Self.hasAudioTrack(file), appAudioActive: busy)
    self.policy = policy
    guard policy == .mixWithOthers else { return }
    let previous = AVAudioSession.sharedInstance()
    saved = Saved(category: previous.category, mode: previous.mode, options: previous.categoryOptions)
    await DictationAudioSession.perform { session in
      try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }
  }

  /// Gives other apps their audio back and puts the category the app had before the video.
  func restore() async {
    guard policy != nil, VideoAudioPolicy.deactivatesOnExit(appAudioActive: appAudioActive || ReadAloudPlayer.isActive)
    else { return }
    let saved = saved
    self.saved = nil
    policy = nil
    await DictationAudioSession.perform { session in
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      if let saved { try? session.setCategory(saved.category, mode: saved.mode, options: saved.options) }
    }
  }
}
