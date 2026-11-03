import ActivityKit
import Observation
import OpenCodeKit
import SwiftUI
import UIKit

/// Where a dictation's text goes: the composer it started in, and how to get back to it.
struct DictationPlace: Equatable {
  enum Route: Equatable {
    case conversation(String)
    case newSession
  }
  /// The conversation's title, "Nova sessão" or "Comentário".
  var title: String
  /// nil: a quote comment, whose sheet is the only way back to it.
  var route: Route?
}

/// The app's dictation in flight, after Abacato V2's `VoiceRecordingDrafts` and `VoiceRecordingSurfaces`: it keeps a
/// recording and the draft it belongs to alive beyond the composer's view (another conversation, Sessões, Você,
/// another app, the locked screen) until the text lands in that draft or the recording is discarded; it shows the
/// in-app strip while that composer is off screen and the Live Activity with Parar. The microphone itself stays open
/// through the audio session and the app's `audio` background mode; neither surface keeps it alive. One capture at a
/// time: a microphone touched in another composer is refused, with a notice on the strip.
@MainActor @Observable final class DictationCaptures {
  static let shared = DictationCaptures()

  enum StripKind: Equatable { case recording, paused, transcribing, ready }
  struct Strip: Equatable {
    var kind: StripKind
    var title: String
    var time: String?
    var place: DictationPlace
  }

  static let refusal = "Pare a gravação para gravar aqui."
  /// The Live Activity's `staleDate` runs this far ahead of the last renewal, renewed every `heartbeat` while recording.
  static let staleAfter: TimeInterval = 180
  static let heartbeat: TimeInterval = 60

  /// The recording the strip and the Live Activity show.
  private(set) var current: VoiceRecordingComposer?
  /// A transcription that landed while its composer was off screen: "Texto pronto" until it is seen or dismissed.
  private(set) var ready: (place: DictationPlace, recording: VoiceRecordingComposer)?
  /// The strip's 4-second notice ("Pare a gravação para gravar aqui.").
  private(set) var notice: String?
  /// Each recording with audio in flight keeps the draft it writes into.
  @ObservationIgnored private var keepers: [ObjectIdentifier: AnyObject] = [:]
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  /// The Live Activity's `id` attribute (the activities themselves are looked up off the main actor).
  @ObservationIgnored private var activityID: String?
  @ObservationIgnored private var activityChain: Task<Void, Never>?
  @ObservationIgnored private var lastContent: DictationActivityAttributes.ContentState?
  @ObservationIgnored private var renewedAt = Date.distantPast
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []
  @ObservationIgnored var theme: AppTheme = .selected
  /// The Live Activity is asked for only when this is on: off in hosted unit tests, which run inside the app.
  @ObservationIgnored var activitiesEnabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

  private init() {
    activityChain = Task { await Self.end(nil) }
    DictationActivityRouter.handler = { [weak self] in self?.current?.finish() }
    let center = NotificationCenter.default
    observers = [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification].map {
      center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateActivity() }
      }
    }
    // A GPT Live call (or anything else that opens the microphone) pauses a dictation whose composer is off screen,
    // as the composer on screen already does.
    observers.append(center.addObserver(forName: .audioCaptureWillStart, object: nil, queue: .main) { [weak self] note in
      let source = (note.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let current = self?.current, source != ObjectIdentifier(current) else { return }
        current.suspend()
      }
    })
  }

  /// What the strip shows (nil: nothing), only while the destination composer is off screen.
  var strip: Strip? {
    if let current, current.presented == 0, let place = current.place, let kind = Self.kind(current) {
      let time = kind == .recording || kind == .paused ? DictationActivityText.time(current.elapsed) : nil
      return Strip(kind: kind, title: Self.title(kind, place: place, elapsed: current.elapsed), time: time, place: place)
    }
    guard let ready, ready.recording.presented == 0 else { return nil }
    return Strip(kind: .ready, title: "Texto pronto em \(ready.place.title)", time: nil, place: ready.place)
  }

  // MARK: The recording's lifecycle (VoiceRecordingComposer)

  /// A microphone touched in a composer while another one records: refused, with the notice on the strip.
  func refuses(_ recording: VoiceRecordingComposer) -> Bool {
    guard let current, current !== recording, current.state == .recording || current.state == .authorizing
    else { return false }
    flash(Self.refusal)
    return true
  }

  /// The recording opened its microphone: it becomes the one shown, and its draft stays alive with it.
  func began(_ recording: VoiceRecordingComposer) {
    current = recording
    if ready?.recording === recording { ready = nil }
    if let keeper = recording.keepAlive() { keepers[ObjectIdentifier(recording)] = keeper }
    updateActivity()
  }

  /// The state changed (pause, resume, hands-free, stop, transcription): the activity follows.
  func changed(_ recording: VoiceRecordingComposer) {
    guard current === recording else { return }
    updateActivity()
  }

  /// The text landed in the recording's draft: seen there, or "Texto pronto" on the strip.
  func delivered(_ recording: VoiceRecordingComposer) {
    if recording.presented == 0, let place = recording.place { ready = (place, recording) }
    ended(recording)
  }

  /// Discarded, delivered or given up (another server): nothing of it stays outside its composer.
  func ended(_ recording: VoiceRecordingComposer) {
    keepers[ObjectIdentifier(recording)] = nil
    guard current === recording else { return }
    current = nil
    updateActivity()
  }

  /// The server's drafts are flushed (a server switch): its recordings are no longer reachable from here.
  func forget(_ recording: VoiceRecordingComposer) {
    if ready?.recording === recording { ready = nil }
    ended(recording)
  }

  /// The meter's sample while recording: renews the activity's `staleDate` once a minute, in the background too.
  func sampled(_ recording: VoiceRecordingComposer) {
    guard current === recording, Date.now.timeIntervalSince(renewedAt) >= Self.heartbeat else { return }
    renewedAt = .distantPast
    lastContent = nil
    updateActivity()
  }

  /// The destination composer is on screen: a "Texto pronto" for it has been seen.
  func appeared(_ recording: VoiceRecordingComposer) {
    if ready?.recording === recording { ready = nil }
  }

  func dismissReady() { ready = nil }

  func flash(_ text: String) {
    notice = text
    noticeTask?.cancel()
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self?.notice = nil
    }
  }

  // MARK: Live Activity

  static func kind(_ recording: VoiceRecordingComposer) -> StripKind? {
    switch recording.state {
    case .recording, .authorizing: .recording
    case .paused: .paused
    case .pending: .transcribing
    case .idle: nil
    }
  }

  private static func title(_ kind: StripKind, place: DictationPlace, elapsed: TimeInterval) -> String {
    switch kind {
    case .recording: DictationActivityText.recording(place.title)
    case .paused: "Gravação pausada · \(place.title)"
    case .transcribing: "Transcrevendo para \(place.title)"
    case .ready: "Texto pronto em \(place.title)"
    }
  }

  /// What the activity shows for `recording` (nil: none). A hold has none yet: it starts hands-free, as in Abacato.
  func content(_ recording: VoiceRecordingComposer?, background: Bool) -> DictationActivityAttributes.ContentState? {
    guard let recording, let kind = Self.kind(recording), recording.gesture.state != .holding || kind != .recording
    else { return nil }
    let roles: [ThemeRole] = [.background, .textStrong, .textSecondary, .primary, .onPrimary]
    let colors = Dictionary(uniqueKeysWithValues: roles.map { role in
      let color = theme.value(role)
      return (String(role.rawValue), [color.red, color.green, color.blue, color.opacity])
    })
    let name = recording.place?.title
    switch kind {
    case .recording:
      return .init(phase: .recording, name: name, started: Date.now.addingTimeInterval(-recording.elapsed), elapsed: nil,
        colors: colors)
    case .paused: return .init(phase: .paused, name: name, started: nil, elapsed: recording.elapsed, colors: colors)
    case .transcribing, .ready:
      // The transcription runs with the app open: in the background the audio waits, saved.
      return .init(phase: background ? .saved : .transcribing, name: name, started: nil, elapsed: recording.elapsed,
        colors: colors)
    }
  }

  private func updateActivity() {
    let background = UIApplication.shared.applicationState == .background
    guard activitiesEnabled, let content = content(current, background: background) else { return endActivity() }
    // The timer runs on the device; a state that only moved the clock is not sent again.
    if var previous = lastContent, previous.phase == .recording, content.phase == .recording,
      abs((previous.started ?? .now).timeIntervalSince(content.started ?? .now)) < 2 {
      previous.started = content.started
      if previous == content { return }
    }
    lastContent = content
    let stale = content.phase == .recording ? Date.now.addingTimeInterval(Self.staleAfter) : nil
    if content.phase == .recording { renewedAt = .now }
    let prior = activityChain
    guard let id = activityID else {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let id = UUID().uuidString
      do {
        _ = try Activity.request(attributes: DictationActivityAttributes(id: id),
          content: ActivityContent(state: content, staleDate: stale, relevanceScore: LiveActivityRelevance.dictation),
          pushType: nil)
        activityID = id
        DictationActivityRouter.id = id
      } catch { DictationAudioTrace.record("live-activity", error: error) }
      return
    }
    activityChain = Task {
      await prior?.value
      await Self.update(id, content: content, stale: stale)
    }
  }

  private func endActivity() {
    lastContent = nil
    DictationActivityRouter.id = nil
    guard let id = activityID else { return }
    activityID = nil
    let prior = activityChain
    activityChain = Task {
      await prior?.value
      await Self.end(id)
    }
  }

  private nonisolated static func update(_ id: String, content: DictationActivityAttributes.ContentState, stale: Date?) async {
    guard let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.attributes.id == id }) else { return }
    await activity.update(ActivityContent(state: content, staleDate: stale, relevanceScore: LiveActivityRelevance.dictation))
  }

  /// Ends `id`'s activity, or with nil every dictation activity (leftovers of an earlier run).
  private nonisolated static func end(_ id: String?) async {
    for activity in Activity<DictationActivityAttributes>.activities where id == nil || activity.attributes.id == id {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}
