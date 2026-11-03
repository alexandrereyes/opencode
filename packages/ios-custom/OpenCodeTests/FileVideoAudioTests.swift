import AVFoundation
import AVKit
import OpenCodeKit
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class FileVideoAudioTests: XCTestCase {
  /// Prepared by `script/test-file-viewer.py` with ffmpeg: the same picture with and without an audio track.
  private func video(audio: Bool) throws -> URL {
    URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment[audio ? "OPENCODE_VIEWER_VIDEO_SOUND" : "OPENCODE_VIEWER_VIDEO_SILENT"]))
  }

  func testSilentVideoMixesAndSoundPlaysOnTheUserRouteThenTheSessionReturns() async throws {
    let session = AVAudioSession.sharedInstance()
    let silent = try video(audio: false)
    let sound = try video(audio: true)
    let silentHasAudio = await FileVideoAudio.hasAudioTrack(silent)
    let soundHasAudio = await FileVideoAudio.hasAudioTrack(sound)
    XCTAssertFalse(silentHasAudio)
    XCTAssertTrue(soundHasAudio)

    // A reading left the session in playback, which silences other apps when a player activates it.
    try session.setCategory(.playback, mode: .spokenAudio)
    let audio = FileVideoAudio()
    await audio.prepare(silent, appAudioActive: false)
    XCTAssertEqual(audio.policy, .mixWithOthers)
    XCTAssertEqual(session.category, .ambient)
    XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    // AVKit's player keeps the category while it plays the silent video.
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    let controller = AVPlayerViewController()
    controller.player = AVPlayer(url: silent)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    controller.player?.play()
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertEqual(session.category, .ambient)
    XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    controller.player?.pause()
    await audio.restore()
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .spokenAudio)

    // With an audio track, after dictation left play-and-record with `.defaultToSpeaker` (no A2DP): the movie used
    // to play under that category, on the iPhone's speaker with AirPods connected (the reported failure). It now
    // gets media playback, which follows the user's route, and the earlier category comes back on exit.
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
    let movie = FileVideoAudio()
    await movie.prepare(sound, appAudioActive: false)
    XCTAssertEqual(movie.policy, .playback(movie: true))
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .moviePlayback)
    XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
    XCTAssertFalse(session.categoryOptions.contains(.defaultToSpeaker))
    // AVKit keeps it while playing, with external playback (its route button) allowed.
    let playing = AVPlayerViewController()
    playing.player = AVPlayer(url: sound)
    window.rootViewController = playing
    playing.player?.play()
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .moviePlayback)
    XCTAssertEqual(playing.player?.allowsExternalPlayback, true)
    playing.player?.pause()
    await movie.restore()
    XCTAssertEqual(session.category, .playAndRecord)
    XCTAssertTrue(session.categoryOptions.contains(.defaultToSpeaker))

    // An audio file plays the same way, in the default mode.
    let track = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_VIEWER_AUDIO_ONLY"]))
    let listening = FileVideoAudio()
    await listening.prepare(track, appAudioActive: false)
    XCTAssertEqual(listening.policy, .playback(movie: false))
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .default)
    await listening.restore()
    XCTAssertEqual(session.category, .playAndRecord)

    // During a voice call the session belongs to the call.
    try session.setCategory(.playAndRecord, mode: .voiceChat)
    let call = FileVideoAudio()
    await call.prepare(silent, appAudioActive: true)
    XCTAssertEqual(call.policy, .unchanged)
    XCTAssertEqual(session.category, .playAndRecord)
    await call.restore()
    XCTAssertEqual(session.category, .playAndRecord)
    try session.setCategory(.soloAmbient)
  }
}
