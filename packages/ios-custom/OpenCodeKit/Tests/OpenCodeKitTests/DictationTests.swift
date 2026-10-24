import CryptoKit
import Foundation
import Testing
@testable import OpenCodeKit

struct DictationTests {
  /// Microphone already allowed: recording starts at the touch; a release within the hold delay continues
  /// hands-free, and a release after it asks to finish (the composer keeps recording under one second).
  @Test func authorizedTouchRecordsAtOnceAndReleaseWithinHoldDelayIsHandsFree() {
    var tap = VoiceRecordingGesture()
    #expect(tap.handle(.pressed) == .startHolding)
    #expect(tap.state == .holding)
    #expect(tap.handle(.moved(CGSize(width: -30, height: -20))) == .none)
    #expect(tap.handle(.ended) == .handsFree)
    #expect(tap.state == .locked)
    #expect(tap.offset == .zero)
    #expect(tap.handle(.held) == .none)
    #expect(tap.handle(.ended) == .none)
    var hold = VoiceRecordingGesture()
    #expect(hold.handle(.pressed) == .startHolding)
    #expect(hold.handle(.held) == .none)
    #expect(hold.state == .holding)
    #expect(hold.handle(.ended) == .finish)
    var kept = VoiceRecordingGesture()
    _ = kept.handle(.pressed); _ = kept.handle(.held)
    _ = kept.handle(.moved(CGSize(width: -40, height: -30)))
    kept.keepRecording()
    #expect(kept.state == .locked)
    #expect(kept.offset == .zero)
    #expect(kept.handle(.ended) == .none)
    #expect(kept.handle(.cancelled) == .none)
    var cancelled = VoiceRecordingGesture()
    _ = cancelled.handle(.pressed)
    #expect(cancelled.handle(.moved(CGSize(width: -100, height: 0))) == .discard)
    #expect(cancelled.handle(.ended) == .none)
  }
  @Test func tapHoldReleaseAndMinimumDuration() {
    #expect(VoiceRecordingGesture.holdDelay == 0.3)
    #expect(VoiceRecordingGesture.minimumDuration == 1)
    #expect(VoiceRecordingAccessibility.duration(0) == "0 segundos")
    #expect(VoiceRecordingAccessibility.duration(1.9) == "1 segundo")
    #expect(VoiceRecordingAccessibility.duration(61) == "1 minuto e 1 segundo")
    var tap = VoiceRecordingGesture()
    #expect(tap.handle(.began) == .none)
    #expect(tap.handle(.ended) == .startLocked)
    #expect(tap.handle(.held) == .none)
    var hold = VoiceRecordingGesture()
    _ = hold.handle(.began)
    #expect(hold.handle(.held) == .startHolding)
    #expect(hold.handle(.ended) == .finish)
    #expect(hold.handle(.ended) == .none)
  }
  @Test func exactCancelAndLockThresholdsAndReversing() {
    var gesture = VoiceRecordingGesture()
    _ = gesture.handle(.began); _ = gesture.handle(.held)
    #expect(gesture.handle(.moved(CGSize(width: -99, height: -79))) == .none)
    #expect(gesture.offset == CGSize(width: -99, height: -79))
    #expect(gesture.handle(.moved(CGSize(width: 10, height: 20))) == .none)
    #expect(gesture.offset == .zero)
    #expect(gesture.handle(.moved(CGSize(width: -100, height: -10))) == .discard)
    #expect(gesture.handle(.ended) == .none)
    gesture = VoiceRecordingGesture()
    _ = gesture.handle(.began); _ = gesture.handle(.held)
    #expect(gesture.handle(.moved(CGSize(width: -10, height: -80))) == .lock)
    #expect(gesture.handle(.ended) == .none)
    #expect(gesture.handle(.cancelled) == .none)
    #expect(gesture.state == .locked)
  }
  @Test func diagonalDominanceAndEarlyEscape() {
    var gesture = VoiceRecordingGesture()
    _ = gesture.handle(.began); _ = gesture.handle(.held)
    #expect(gesture.handle(.moved(CGSize(width: -110, height: -120))) == .lock)
    gesture = VoiceRecordingGesture()
    _ = gesture.handle(.began); _ = gesture.handle(.held)
    #expect(gesture.handle(.moved(CGSize(width: -150, height: -90))) == .discard)
    gesture = VoiceRecordingGesture()
    _ = gesture.handle(.began)
    #expect(gesture.handle(.moved(CGSize(width: -21, height: 0))) == .discard)
    #expect(gesture.handle(.held) == .none)
  }
  @Test func cancellationNeverFinishes() {
    for held in [false, true] {
      var gesture = VoiceRecordingGesture()
      _ = gesture.handle(.began)
      if held { _ = gesture.handle(.held) }
      #expect(gesture.handle(.cancelled) == .discard)
      #expect(gesture.handle(.ended) == .none)
    }
  }
  @Test func pinnedManifestAndDownloadIntegrityResume() throws {
    let manifest = TranscriptionManifest.parakeetUltra
    #expect(manifest.totalBytes == 632_162_964)
    #expect(manifest.files.count == 18)
    #expect(manifest.baseURL.absoluteString.hasSuffix("95eaa59a39d4394f047a4dc5cce480388a60d1b6"))
    #expect(manifest.files.allSatisfy { $0.sha256.count == 64 })
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("modelo conferido".utf8)
    let file = TranscriptionManifest.File(path: "Encoder.mlmodelc/weights/weight.bin", bytes: Int64(bytes.count),
      sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    let files = TranscriptionModelFiles(root: root, manifest: .init(version: "test", baseURL: URL(string: "https://example.invalid")!, files: [file]))
    try files.prepareRoot()
    let download = root.appending(path: "download")
    try Data(repeating: 0, count: bytes.count).write(to: download)
    #expect(throws: TranscriptionError.integrity) { try files.stage(file, from: download) }
    #expect(!FileManager.default.fileExists(atPath: download.path))
    #expect(throws: TranscriptionError.integrity) { try files.install() }
    try TranscriptionModelFiles.prepare(files.resumeDataURL(for: file).deletingLastPathComponent())
    try Data("resume".utf8).write(to: files.resumeDataURL(for: file))
    let reopened = TranscriptionModelFiles(root: root, manifest: files.manifest)
    #expect(try Data(contentsOf: reopened.resumeDataURL(for: file)) == Data("resume".utf8))
    try bytes.write(to: download)
    try files.stage(file, from: download)
    #expect(reopened.missingFiles().isEmpty)
    #expect(reopened.stagedBytes() == Int64(bytes.count))
    try reopened.install()
    #expect(reopened.isInstalled)
    #expect(!FileManager.default.fileExists(atPath: reopened.partial.path))
    #expect(reopened.bytesOnDisk == Int64(bytes.count))
    try reopened.remove()
    #expect(!reopened.isInstalled)
  }
  @Test func pendingAudioSurvivesDraftAttachmentCleanupAndRestoration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = DraftPersistence(server: "local", sessionID: "test", root: root)
    let snapshot = DraftSnapshot(document: .init(text: "Rascunho"), dictationPending: true)
    try await persistence.save(snapshot)
    let audio = persistence.directory.appending(path: "dictation.caf")
    try Data("audio".utf8).write(to: audio)
    try await persistence.cleanAttachments(retaining: [])
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(try await persistence.load().0 == snapshot)
  }
}
