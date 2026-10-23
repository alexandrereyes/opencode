import AVFoundation
import OpenCodeKit
import SwiftUI
import XCTest
import os
@testable import OpenCode

@MainActor final class DictationPipelineTests: XCTestCase {
  private func wait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let satisfied = await predicate()
    XCTAssertTrue(satisfied)
  }
  func testQueueWaitsForModelThenTranscribesSeriallyAndRetriesFailure() async throws {
    let source = DictationTestSource()
    defer { try? FileManager.default.removeItem(at: source.files.root) }
    let engine = DictationTestEngine()
    let transcription = TranscriptionController(source: source, engine: engine, monitorsNetwork: false, decode: { _ in [0.25] })
    var received: [String] = []
    let first = DictationJob(file: URL(fileURLWithPath: "/unused")) { received.append($0) }
    let second = DictationJob(file: URL(fileURLWithPath: "/unused2")) { received.append($0) }
    transcription.enqueue(first); transcription.enqueue(second)
    XCTAssertEqual(first.state, .waiting)
    let calls = await engine.calls
    XCTAssertEqual(calls, 0)
    transcription.download(cellular: false)
    XCTAssertEqual(source.starts, [false])
    await engine.setFail(true)
    transcription.setActive(false)
    source.install()
    try await wait { transcription.status == .ready }
    XCTAssertEqual(first.state, .waiting)
    let backgroundCalls = await engine.calls
    XCTAssertEqual(backgroundCalls, 0)
    transcription.setActive(true)
    try await wait { if case .failed = first.state { return true }; return false }
    XCTAssertTrue(received.isEmpty)
    await engine.setFail(false)
    transcription.retry(first)
    transcription.retry(second)
    try await wait { received.count == 2 && transcription.jobs.isEmpty && transcription.canRemove }
    XCTAssertTrue(transcription.jobs.isEmpty)
    XCTAssertEqual(received, ["Texto transcrito", "Texto transcrito"])
    await transcription.removeModel()
    XCTAssertEqual(transcription.status, .missing)
  }
  func testInsertionUsesNativeIncrementalPathPreservingTokenAndUndo() async throws {
    let draft = ConversationDraft(server: "dictation-test", id: UUID().uuidString)
    let token = ComposerToken(kind: .skill, id: "sample", text: "$sample")
    draft.text = ComposerDocument(text: "$sample Final", tokens: [.init(start: 0, end: 7, token: token)]).attributed
    draft.selection = NSRange(location: 1, length: 0)
    let owner = UUID()
    draft.editorOwner = owner
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.rootViewController = UIHostingController(rootView: ComposerTextView(draft: draft, theme: .selected, expanded: true, owner: owner))
    window.makeKeyAndVisible(); window.layoutIfNeeded()
    defer { window.isHidden = true }
    try await wait { draft.input != nil }
    let input = try XCTUnwrap(draft.input)
    let attachment = try XCTUnwrap(input.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? ComposerTokenAttachment)
    let revision = draft.sourceRevision
    await draft.insertTranscription("Olá, revisão")
    XCTAssertEqual(draft.document.text, "$sample Olá, revisão Final")
    XCTAssertEqual(draft.document.validTokens.map(\.token), [token])
    XCTAssertEqual(draft.sourceRevision, revision)
    XCTAssertTrue(attachment === input.textStorage.attribute(.attachment, at: 0, effectiveRange: nil) as? ComposerTokenAttachment)
    XCTAssertTrue(draft.dictationReview)
    XCTAssertEqual(draft.sendRevision, 0)
    XCTAssertEqual(draft.selection.location, "\u{FFFC} Olá, revisão".utf16.count)
    input.undoManager?.undo()
    XCTAssertEqual(draft.document.text, "$sample Final")
    draft.editorOwner = nil
    draft.selection = NSRange(location: 1, length: 0)
    await draft.insertTranscription("Fora da tela")
    XCTAssertEqual(draft.document.text, "$sample Fora da tela Final")
    XCTAssertEqual(draft.document.validTokens.map(\.token), [token])
    XCTAssertEqual(draft.sourceRevision, revision + 1)
    XCTAssertEqual(draft.selection.location, "\u{FFFC} Fora da tela".utf16.count)
  }
  func testPermissionReleaseCannotStartLateAndLockedInterruptionPauses() async throws {
    let capture = DictationTestCapture()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let recording = VoiceRecordingComposer(file: root.appending(path: "dictation.caf"), capture: capture)
    defer { recording.discard(); try? FileManager.default.removeItem(at: root) }
    recording.handle(.began); recording.handle(.held)
    try await wait { capture.permission != nil }
    recording.handle(.ended)
    capture.permission?.resume(returning: true); capture.permission = nil
    await Task.yield()
    XCTAssertEqual(capture.starts, 0)
    capture.waits = false
    recording.handle(.began); recording.handle(.ended)
    try await wait { recording.state == .recording }
    recording.suspend()
    XCTAssertEqual(recording.state, .paused)
    XCTAssertEqual(capture.pauses, 1)
    XCTAssertEqual(recording.gesture.state, .locked)
  }
  func testVoiceOverActivationAndMeter() {
    let target = VoiceRecordingTouchTarget.TouchView()
    var gesture = VoiceRecordingGesture()
    target.event = { _ = gesture.handle($0) }
    XCTAssertFalse(target.accessibilityActivate())
    target.available = true
    XCTAssertTrue(target.accessibilityActivate())
    XCTAssertEqual(gesture.state, .locked)
    XCTAssertEqual(MicrophoneVoiceCapture.displayLevel(decibels: -160), 0)
    XCTAssertEqual(MicrophoneVoiceCapture.displayLevel(decibels: -25), 0.5)
    XCTAssertEqual(MicrophoneVoiceCapture.displayLevel(decibels: 5), 1)
  }
  func testActiveCallGateCannotOpenTheMicrophone() {
    let capture = DictationTestCapture()
    let recording = VoiceRecordingComposer(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), capture: capture)
    recording.willUseAudio = { false }
    recording.handle(.began); recording.handle(.ended)
    XCTAssertEqual(recording.state, .idle)
    XCTAssertNil(capture.permission)
    XCTAssertEqual(capture.starts, 0)
    recording.discard()
  }
  func testRealPCMDecodeAndOpenCAFPreviewKeepTheOriginalUnchanged() throws {
    let fixture = try XCTUnwrap(Bundle.main.url(forResource: "dictation-fixture", withExtension: "caf"))
    let samples = try TranscriptionAudio.samples(fixture)
    XCTAssertEqual(Double(samples.count) / 16_000, 7.957125, accuracy: 0.01)
    XCTAssertTrue(samples.allSatisfy(\.isFinite))
    XCTAssertTrue(samples.contains { abs($0) > 0.05 })
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try TranscriptionModelFiles.prepare(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let pcm = root.appending(path: "open.caf")
    let preview = root.appending(path: "preview.caf")
    var bytes = try Data(contentsOf: fixture)
    let chunk = try XCTUnwrap(bytes.range(of: Data("data".utf8)))
    bytes.replaceSubrange(chunk.upperBound..<(chunk.upperBound + 8), with: Data(repeating: 255, count: 8))
    try bytes.write(to: pcm)
    try VoiceRecordingSnapshot.copy(pcm: pcm, to: preview)
    XCTAssertEqual(try Data(contentsOf: pcm), bytes)
    let result = try VoiceRecordingSnapshot.inspect(preview)
    XCTAssertEqual(result.duration, 7.957125, accuracy: 0.001)
    XCTAssertEqual(result.waveform.count, 64)
    XCTAssertTrue(result.waveform.contains { $0 > 0.5 })
  }
  func testDownloadConsentAndCellularChoiceResumeAfterRelaunch() async throws {
    let suite = "dictation-network-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = DictationTestSource()
    defer { try? FileManager.default.removeItem(at: source.files.root) }
    let first = TranscriptionController(source: source, engine: DictationTestEngine(), defaults: defaults, monitorsNetwork: false)
    first.start()
    XCTAssertTrue(source.starts.isEmpty)
    first.download(cellular: true)
    let reopened = TranscriptionController(source: source, engine: DictationTestEngine(), defaults: defaults, monitorsNetwork: false)
    reopened.start()
    XCTAssertEqual(source.starts, [true, true])
    XCTAssertTrue(reopened.cellular)
    await reopened.removeModel()
    let removed = TranscriptionController(source: source, engine: DictationTestEngine(), defaults: defaults, monitorsNetwork: false)
    removed.start()
    XCTAssertFalse(removed.cellular)
    XCTAssertEqual(source.starts, [true, true])
  }
  func testRecordingFailureRetainsAudioUntilSuccessfulRetry() async throws {
    let source = DictationTestSource()
    source.install()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: source.files.root)
    }
    let engine = DictationTestEngine()
    await engine.setFail(true)
    let transcription = TranscriptionController(source: source, engine: engine, monitorsNetwork: false)
    let capture = DictationTestCapture()
    capture.waits = false
    capture.writesFixture = true
    let recording = VoiceRecordingComposer(file: root.appending(path: "dictation.caf"), capture: capture, transcription: transcription)
    defer { recording.discard() }
    var received: String?
    recording.receive = { received = $0 }
    recording.handle(.began); recording.handle(.ended)
    try await wait { recording.state == .recording }
    recording.finish()
    try await wait { if case .failed? = recording.job?.state { return true }; return false }
    XCTAssertTrue(FileManager.default.fileExists(atPath: recording.file.path))
    XCTAssertNil(received)
    await engine.setFail(false)
    recording.retry()
    try await wait { recording.state == .idle && received != nil }
    XCTAssertEqual(received, "Texto transcrito")
    XCTAssertFalse(FileManager.default.fileExists(atPath: recording.file.path))
  }
}

actor DictationTestEngine: TranscriptionEngine {
  private(set) var calls = 0
  private var fail = false
  func setFail(_ value: Bool) { fail = value }
  func load(from directory: URL) async throws {}
  func transcribe(_ samples: [Float]) async throws -> String {
    calls += 1
    if fail { throw TranscriptionError.integrity }
    return "Texto transcrito"
  }
  func unload() async {}
}
final class DictationTestSource: TranscriptionModelSource, @unchecked Sendable {
  let files = TranscriptionModelFiles(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), manifest: .parakeetUltra)
  private struct State { var handler: (@Sendable (TranscriptionDownloadEvent) -> Void)?; var starts: [Bool] = [] }
  private let state = OSAllocatedUnfairLock(initialState: State())
  var starts: [Bool] { state.withLock { $0.starts } }
  func setHandler(_ handler: @escaping @Sendable (TranscriptionDownloadEvent) -> Void) { state.withLock { $0.handler = handler } }
  func start(cellular: Bool) { state.withLock { $0.starts.append(cellular) } }
  func stop() async {}
  func install() {
    try? FileManager.default.createDirectory(at: files.installed, withIntermediateDirectories: true)
    state.withLock { $0.handler }?(.installed)
  }
}
@MainActor final class DictationTestCapture: VoiceRecordingCapture {
  var waits = true
  var writesFixture = false
  var permission: CheckedContinuation<Bool, Never>?
  var starts = 0
  var pauses = 0
  func authorize() async -> Bool { waits ? await withCheckedContinuation { permission = $0 } : true }
  func start(at file: URL) throws {
    starts += 1
    if writesFixture {
      try FileManager.default.copyItem(at: XCTUnwrap(Bundle.main.url(forResource: "dictation-fixture", withExtension: "caf")), to: file)
    }
  }
  var elapsed: TimeInterval { 2 }
  var level: Float { 0.5 }
  func pause() { pauses += 1 }
  func resume() throws {}
  func stop() {}
}
