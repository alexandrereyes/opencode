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
    try await wait { recording.state == .recording && recording.elapsed > 0 }
    recording.finish()
    try await wait { if case .failed? = recording.job?.state { return true }; return false }
    XCTAssertTrue(FileManager.default.fileExists(atPath: recording.file.path))
    XCTAssertNil(received)
    await engine.setFail(false)
    recording.retry()
    try await wait { recording.state == .idle && received != nil }
    XCTAssertEqual(received, "Texto transcrito")
    XCTAssertFalse(FileManager.default.fileExists(atPath: recording.file.path))
    // The next recording's panel starts at zero, not with the time and levels of this one.
    capture.waits = true
    recording.handle(.began); recording.handle(.ended)
    try await wait { capture.permission != nil }
    XCTAssertEqual(recording.state, .authorizing)
    XCTAssertEqual(recording.elapsed, 0)
    XCTAssertTrue(recording.levels.allSatisfy { $0 == 0 })
    capture.permission?.resume(returning: false); capture.permission = nil
    try await wait { recording.state == .idle }
  }
  private func granted(recorded: TimeInterval = 2) -> (VoiceRecordingComposer, DictationTestCapture) {
    let capture = DictationTestCapture()
    capture.waits = false; capture.granted = true; capture.recorded = recorded
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let recording = VoiceRecordingComposer(file: root.appending(path: "dictation.caf"), capture: capture)
    addTeardownBlock { @MainActor in recording.discard(); try? FileManager.default.removeItem(at: root) }
    return (recording, capture)
  }
  /// Microphone already allowed: recording starts at the touch; a quick release continues hands-free, and so does
  /// releasing a hold under one second (nothing is lost); one second or more finishes for transcription.
  func testAuthorizedTouchRecordsAtOnceAndOnlyHoldOverOneSecondFinishes() async throws {
    let (recording, capture) = granted()
    recording.handle(.began)
    XCTAssertEqual(recording.gesture.state, .holding)
    try await wait { recording.state == .recording }
    XCTAssertEqual(capture.starts, 1)
    recording.handle(.ended)
    XCTAssertEqual(recording.state, .recording)
    XCTAssertEqual(recording.gesture.state, .locked)
    recording.discard()
    capture.recorded = 0.5
    recording.handle(.began); recording.handle(.held)
    try await wait { recording.state == .recording }
    recording.handle(.ended)
    XCTAssertEqual(recording.state, .recording)
    XCTAssertEqual(recording.gesture.state, .locked)
    recording.discard()
    capture.recorded = 2
    recording.handle(.began); recording.handle(.held)
    try await wait { recording.state == .recording }
    recording.handle(.ended)
    XCTAssertEqual(recording.state, .pending)
    XCTAssertEqual(capture.starts, 3)
  }
  /// Locked, or held for one second or more, an interruption keeps a paused draft with "Parar e transcrever";
  /// a shorter hold is discarded. Nothing resumes on its own.
  func testInterruptionsKeepPausedDraftUnlessHeldUnderOneSecond() async throws {
    for (locked, recorded) in [(true, 2.0), (true, 0.5), (false, 2.0), (false, 0.5)] {
      let (recording, capture) = granted(recorded: recorded)
      recording.handle(.began)
      recording.handle(locked ? .ended : .held)
      try await wait { recording.state == .recording }
      recording.suspend()
      let kept = locked || recorded >= 1
      XCTAssertEqual(recording.state, kept ? .paused : .idle, "locked \(locked), \(recorded) s")
      XCTAssertEqual(recording.gesture.state, kept ? .locked : .idle, "locked \(locked), \(recorded) s")
      XCTAssertEqual(capture.pauses, kept ? 1 : 0)
    }
  }
  /// The system cancelling a hold (Home, lock, alert) keeps a paused draft from one second on and ignores the
  /// release that may still arrive; a shorter hold is discarded.
  func testInterruptedHoldKeepsDraftOrDiscardsAndIgnoresLateRelease() async throws {
    for recorded in [2.0, 0.5] {
      let (recording, capture) = granted(recorded: recorded)
      recording.handle(.began); recording.handle(.held)
      try await wait { recording.state == .recording }
      recording.handle(.cancelled)
      recording.handle(.ended)
      XCTAssertEqual(recording.state, recorded >= 1 ? .paused : .idle, "\(recorded) s")
      XCTAssertEqual(capture.pauses, recorded >= 1 ? 1 : 0)
      if recorded >= 1 { XCTAssertEqual(recording.gesture.state, .locked) }
    }
  }
  private func warmup(build: String, engine: DictationWarmupEngine, defaults: UserDefaults) -> (TranscriptionController, DictationTestSource) {
    let source = DictationTestSource()
    source.install()
    addTeardownBlock { try? FileManager.default.removeItem(at: source.files.root) }
    return (TranscriptionController(source: source, engine: engine, defaults: defaults, monitorsNetwork: false,
      build: build, warmupDelay: .zero, decode: { _ in [0.25] }), source)
  }
  private func suite() throws -> UserDefaults {
    let name = "dictation-warmup-\(UUID().uuidString)"
    addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    return try XCTUnwrap(UserDefaults(suiteName: name))
  }
  func testRecordingPrewarmSharesOneLoadWithTheQueuedRecording() async throws {
    let engine = DictationWarmupEngine(gated: true)
    let (transcription, _) = warmup(build: "build-a", engine: engine, defaults: try suite())
    transcription.prewarm(); transcription.prewarm()
    try await wait { await engine.waiting }
    XCTAssertEqual(transcription.status, .preparing)
    XCTAssertTrue(transcription.optimizing)
    XCTAssertEqual(transcription.label, "Otimizando o modelo para este iPhone (uma vez por atualização)…")
    var received: [String] = []
    let job = DictationJob(file: URL(fileURLWithPath: "/unused")) { received.append($0) }
    transcription.enqueue(job)
    XCTAssertEqual(job.state, .waiting)
    XCTAssertFalse(transcription.canRemove)
    await engine.open()
    try await wait { received == ["Texto aquecido"] && transcription.canRemove }
    let loads = await engine.loads
    XCTAssertEqual(loads, 1)
    XCTAssertFalse(transcription.optimizing)
    transcription.setActive(false)
    try await wait { await engine.unloads == 1 }
    transcription.setActive(true)
    transcription.prewarm()
    XCTAssertFalse(transcription.optimizing, "The same build was already compiled")
    try await wait { await engine.loads == 2 && transcription.status == .ready }
  }
  func testBackgroundingDuringPrewarmUnloadsOnlyAfterTheLoadFinishes() async throws {
    let engine = DictationWarmupEngine(gated: true)
    let (transcription, _) = warmup(build: "build-a", engine: engine, defaults: try suite())
    transcription.prewarm()
    try await wait { await engine.waiting }
    transcription.setActive(false)
    await Task.yield()
    let early = await engine.unloads
    XCTAssertEqual(early, 0)
    await engine.open()
    try await wait { await engine.unloads == 1 && transcription.status == .ready }
    let loads = await engine.loads
    XCTAssertEqual(loads, 1)
  }
  func testLaunchPrewarmRunsOnceAfterEachUpdateOrDownload() async throws {
    let defaults = try suite()
    let first = DictationWarmupEngine(gated: false)
    let (launch, _) = warmup(build: "build-a", engine: first, defaults: defaults)
    launch.start()
    try await wait { await first.loads == 1 && launch.status == .ready }
    let same = DictationWarmupEngine(gated: false)
    let (relaunch, _) = warmup(build: "build-a", engine: same, defaults: defaults)
    relaunch.start()
    try await Task.sleep(for: .milliseconds(200))
    let skipped = await same.loads
    XCTAssertEqual(skipped, 0)
    let updated = DictationWarmupEngine(gated: false)
    let (update, _) = warmup(build: "build-b", engine: updated, defaults: defaults)
    update.start()
    try await wait { await updated.loads == 1 }
    let downloaded = DictationWarmupEngine(gated: false)
    let source = DictationTestSource()
    defer { try? FileManager.default.removeItem(at: source.files.root) }
    let download = TranscriptionController(source: source, engine: downloaded, defaults: defaults, monitorsNetwork: false,
      build: "build-b", warmupDelay: .zero)
    download.download(cellular: false)
    source.install()
    try await wait { await downloaded.loads == 1 }
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
  var granted = false
  var recorded: TimeInterval = 2
  var authorized: Bool { granted }
  var permission: CheckedContinuation<Bool, Never>?
  var starts = 0
  var pauses = 0
  func authorize() async -> Bool { waits ? await withCheckedContinuation { permission = $0 } : true }
  func start(at file: URL) async throws {
    starts += 1
    if writesFixture {
      try FileManager.default.copyItem(at: XCTUnwrap(Bundle.main.url(forResource: "dictation-fixture", withExtension: "caf")), to: file)
    }
  }
  var elapsed: TimeInterval { recorded }
  var level: Float { 0.5 }
  func pause() { pauses += 1 }
  func resume() async throws {}
  func stop() {}
}
actor DictationWarmupEngine: TranscriptionEngine {
  private(set) var loads = 0
  private(set) var unloads = 0
  private var gated: Bool
  private var gate: CheckedContinuation<Void, Never>?
  init(gated: Bool) { self.gated = gated }
  var waiting: Bool { gate != nil }
  func open() { gated = false; gate?.resume(); gate = nil }
  func load(from directory: URL) async throws {
    loads += 1
    if gated { await withCheckedContinuation { gate = $0 } }
  }
  func transcribe(_ samples: [Float]) async throws -> String { "Texto aquecido" }
  func unload() async { unloads += 1 }
}
