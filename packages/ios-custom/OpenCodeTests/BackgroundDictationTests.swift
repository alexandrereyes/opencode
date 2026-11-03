import ActivityKit
import OpenCodeKit
import UIKit
import XCTest
@testable import OpenCode

/// The composer dictation outside its composer (`DictationCaptures`): it goes on when the composer leaves the screen
/// or the app goes to the background, its text lands only in the draft it started in, one capture at a time, and the
/// Live Activity follows it and ends with it. The fake microphone and engine; no server, model or real microphone.
@MainActor final class BackgroundDictationTests: XCTestCase {
  private var root: URL!
  private var source: DictationTestSource!
  private var transcription: TranscriptionController!
  private var drafts: [ConversationDraft] = []

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    source = DictationTestSource()
    source.install()
    transcription = TranscriptionController(source: source, engine: DictationTestEngine(), monitorsNetwork: false,
      decode: { _ in [0.25] })
  }

  override func tearDown() async throws {
    for draft in drafts { draft.recording.discard() }
    drafts = []
    DictationCaptures.shared.dismissReady()
    DictationCaptures.shared.activitiesEnabled = false
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: source.files.root)
  }

  private func wait(_ predicate: () async -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let satisfied = await predicate()
    XCTAssertTrue(satisfied)
  }

  private func draft(_ title: String, recorded: TimeInterval = 2) -> (ConversationDraft, DictationTestCapture) {
    let capture = DictationTestCapture()
    capture.waits = false; capture.granted = true; capture.writesFixture = true; capture.recorded = recorded
    let draft = ConversationDraft(server: "background-dictation", id: UUID().uuidString, root: root)
    let transcription = transcription!
    draft.recordingFactory = { VoiceRecordingComposer(file: $0, capture: capture, transcription: transcription) }
    draft.recording.place = DictationPlace(title: title, route: .conversation("ses_" + title))
    draft.recording.presented = 1
    drafts.append(draft)
    return (draft, capture)
  }

  /// A tap: recording starts hands-free.
  private func record(_ draft: ConversationDraft) async throws {
    draft.recording.handle(.began); draft.recording.handle(.ended)
    try await wait { draft.recording.state == .recording }
  }

  func testHandsFreeRecordingGoesOnOffScreenAndInTheBackgroundShownByTheStrip() async throws {
    let (draft, capture) = draft("Conversa A")
    try await record(draft)
    XCTAssertNil(DictationCaptures.shared.strip, "its composer is on screen")
    draft.recording.presented = 0
    draft.recording.leftScreen()
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    XCTAssertEqual(draft.recording.state, .recording)
    XCTAssertEqual(capture.calls, ["start"], "neither paused nor stopped")
    XCTAssertTrue(DictationCaptures.shared.current === draft.recording)
    let strip = try XCTUnwrap(DictationCaptures.shared.strip)
    XCTAssertEqual(strip.kind, .recording)
    XCTAssertEqual(strip.title, "Gravando para Conversa A")
    XCTAssertEqual(strip.place.route, .conversation("ses_Conversa A"))
    // Back on screen: the composer shows it again, not the strip.
    draft.recording.presented = 1
    XCTAssertNil(DictationCaptures.shared.strip)
  }

  func testAHoldThatLeavesBecomesAPausedDraftOrIsDiscardedUnderOneSecond() async throws {
    let (kept, keptCapture) = draft("Longa")
    kept.recording.handle(.began); kept.recording.handle(.held)
    try await wait { kept.recording.state == .recording }
    kept.recording.leftScreen()
    XCTAssertEqual(kept.recording.state, .paused)
    XCTAssertEqual(keptCapture.calls, ["start", "pause"])
    kept.recording.discard()
    let (short, shortCapture) = draft("Curta", recorded: 0.4)
    short.recording.handle(.began); short.recording.handle(.held)
    try await wait { short.recording.state == .recording }
    short.recording.leftScreen()
    XCTAssertEqual(short.recording.state, .idle)
    XCTAssertEqual(shortCapture.calls, ["start", "stop"])
  }

  /// The text goes to the draft the recording started in, never to the composer on screen; there it shows as
  /// "Texto pronto" until that composer is seen. Meanwhile the draft is kept alive by the recording.
  func testTheTextLandsOnlyInItsOwnDraftAndIsReadyUntilSeen() async throws {
    let (owner, _) = draft("Conversa A")
    let (other, _) = draft("Conversa B")
    try await record(owner)
    owner.recording.presented = 0
    owner.recording.leftScreen()
    weak var kept = owner
    XCTAssertNotNil(kept)
    owner.recording.finish()
    try await wait { owner.recording.state == .idle }
    XCTAssertEqual(owner.text.string, "Texto transcrito")
    XCTAssertEqual(other.text.string, "", "the composer on screen gets nothing")
    let strip = try XCTUnwrap(DictationCaptures.shared.strip)
    XCTAssertEqual(strip.kind, .ready)
    XCTAssertEqual(strip.title, "Texto pronto em Conversa A")
    XCTAssertNil(DictationCaptures.shared.current)
    owner.recording.presented = 1
    DictationCaptures.shared.appeared(owner.recording)
    XCTAssertNil(DictationCaptures.shared.strip)
  }

  func testAnotherComposerIsRefusedWhileOneRecords() async throws {
    let (owner, _) = draft("Conversa A")
    let (other, otherCapture) = draft("Conversa B")
    try await record(owner)
    owner.recording.presented = 0
    other.recording.handle(.began); other.recording.handle(.ended)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(other.recording.state, .idle)
    XCTAssertEqual(otherCapture.starts, 0)
    XCTAssertEqual(DictationCaptures.shared.notice, DictationCaptures.refusal)
    XCTAssertTrue(DictationCaptures.shared.current === owner.recording)
    // Descartar stays Descartar: the owner's recording ends and the other composer may record.
    owner.recording.discard()
    XCTAssertNil(DictationCaptures.shared.current)
    try await record(other)
  }

  /// What the activity carries: the phase, the destination's title and the time, never the text.
  func testActivityContentIsTheStateTitleAndTime() async throws {
    let (owner, _) = draft("Nova sessão")
    try await record(owner)
    try await wait { owner.recording.elapsed > 0 }
    let captures = DictationCaptures.shared
    let recording = try XCTUnwrap(captures.content(owner.recording, background: false))
    XCTAssertEqual(recording.phase, .recording)
    XCTAssertEqual(recording.name, "Nova sessão")
    XCTAssertEqual(recording.started?.timeIntervalSinceNow ?? 0, -2, accuracy: 1)
    XCTAssertEqual(DictationActivityText.render(recording, stale: false),
      .init(title: "Gravando para Nova sessão", body: nil, timer: true, stop: true))
    XCTAssertEqual(DictationActivityText.render(recording, stale: true).stop, false)
    owner.recording.pause()
    let paused = try XCTUnwrap(captures.content(owner.recording, background: false))
    XCTAssertEqual(paused.phase, .paused)
    XCTAssertEqual(DictationActivityText.render(paused, stale: false).title, "Gravação pausada · 0:02")
    owner.recording.finish()
    let saved = try XCTUnwrap(captures.content(owner.recording, background: true))
    XCTAssertEqual(saved.phase, .saved, "in the background the transcription waits for the app")
    XCTAssertEqual(Set(Mirror(reflecting: saved).children.compactMap(\.label)), ["phase", "name", "started", "elapsed", "colors"])
  }

  /// The Live Activity starts hands-free, follows pause and Parar from the activity (the intent's handler), and ends
  /// with the recording; the call's and the agents' activities are another type and are left alone.
  func testLiveActivityStartsHandsFreeFollowsAndEnds() async throws {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { throw XCTSkip("Live Activities are off") }
    let captures = DictationCaptures.shared
    captures.activitiesEnabled = true
    // A release before one second keeps recording hands-free, as in WhatsApp.
    let (owner, capture) = draft("Conversa A", recorded: 0.5)
    owner.recording.handle(.began); owner.recording.handle(.held)
    try await wait { owner.recording.state == .recording }
    XCTAssertTrue(Activity<DictationActivityAttributes>.activities.isEmpty, "a hold has no activity yet")
    owner.recording.handle(.ended)
    XCTAssertEqual(owner.recording.state, .recording)
    capture.recorded = 2
    try await wait { Activity<DictationActivityAttributes>.activities.count == 1 }
    let activity = try XCTUnwrap(Activity<DictationActivityAttributes>.activities.first)
    XCTAssertEqual(activity.content.state.phase, .recording)
    XCTAssertEqual(activity.content.state.name, "Conversa A")
    XCTAssertEqual(activity.content.relevanceScore, LiveActivityRelevance.dictation)
    XCTAssertNotNil(activity.content.staleDate)
    owner.recording.pause()
    try await wait { activity.content.state.phase == .paused }
    owner.recording.resume()
    try await wait { owner.recording.state == .recording && activity.content.state.phase == .recording }
    // "Parar gravação" on the activity.
    _ = try await StopDictationIntent(id: activity.attributes.id).perform()
    XCTAssertNotEqual(owner.recording.state, .recording)
    XCTAssertEqual(capture.calls.last, "stop")
    try await wait { owner.recording.state == .idle }
    try await wait { Activity<DictationActivityAttributes>.activities.isEmpty }
    XCTAssertEqual(owner.text.string, "Texto transcrito")
  }
}
