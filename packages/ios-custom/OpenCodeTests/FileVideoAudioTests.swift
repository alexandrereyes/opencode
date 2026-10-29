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

  func testVideoWithoutAudioMixesWithOtherAppsAndRestoresTheSession() async throws {
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

    // With an audio track the player behaves as before.
    let normal = FileVideoAudio()
    await normal.prepare(sound, appAudioActive: false)
    XCTAssertEqual(normal.policy, .unchanged)
    XCTAssertEqual(session.category, .playback)
    await normal.restore()
    XCTAssertEqual(session.category, .playback)

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
