import AVFoundation
import AppKit
import Observation
import OpenCodeKit

// The Mac's counterparts of the iPhone pieces the shared conversation files (`ConversationStore`,
// `ConversationRegistry`, `ConversationDraft`) name. Each keeps the iPhone's API; only the platform part differs.

/// The transcript view kept with a conversation (`TranscriptMemory.controller`) is the Mac's AppKit transcript.
typealias TranscriptViewController = MacTranscriptController

/// What the chat column shows about the transcript, like the iPhone's.
@MainActor @Observable final class TranscriptState {
  /// Content continues below the viewport: ↓ **Ir para a mais recente**.
  var jumpToLatest = false
  /// Points the pinned prompt covers at the top.
  var stickyHeight: CGFloat = 0
  /// The transcript is not on screen yet: its first frame waits for the final position.
  var restoring = true
  /// The saved place is older than the history this opening reads: offer to keep paging.
  var resumeOffered = false
}

/// Measured heights, kept with the conversation so a rebuilt transcript lays out at once. An entry is valid for
/// the same item content and width (the Mac has no Dynamic Type).
@MainActor final class TranscriptHeights {
  private struct Entry {
    let kind: TranscriptItem.Kind
    let width: CGFloat
    let height: CGFloat
  }
  private var entries: [String: Entry] = [:]

  func height(_ item: TranscriptItem, width: CGFloat) -> CGFloat? {
    guard let entry = entries[item.id], entry.width == width, entry.kind == item.kind else { return nil }
    return entry.height
  }

  /// The item's last measured height whatever its content: closer than any estimate when a row comes back.
  func last(_ id: String, width: CGFloat) -> CGFloat? {
    guard let entry = entries[id], entry.width == width else { return nil }
    return entry.height
  }

  func store(_ height: CGFloat, for item: TranscriptItem, width: CGFloat) {
    entries[item.id] = Entry(kind: item.kind, width: width, height: height)
  }

  func removeAll() { entries.removeAll() }
}

/// Ouvir: the system's Brazilian Portuguese voice reads the answer; a second click on the same answer stops it.
/// The iPhone's player (server voices, lock-screen controls) depends on UIKit and the audio session.
@MainActor @Observable final class ConversationReadAloud: NSObject, AVSpeechSynthesizerDelegate {
  /// The footer message of the answer being read.
  private(set) var messageID: String?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func read(_ response: ReadAloud.Response, title: String, client: OpenCodeClient) {
    let same = messageID == response.messageID
    stop()
    guard !same else { return }
    let utterance = AVSpeechUtterance(string: response.text)
    utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
    messageID = response.messageID
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    messageID = nil
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.messageID = nil }
  }
}

/// The iPhone records and transcribes on the device; the Mac composer uses the system's dictation instead, so its
/// drafts never have a recording pending.
@MainActor final class VoiceRecordingComposer {
  var receive: @MainActor (String) async -> Void = { _ in }
  var pendingChanged: (Bool) -> Void = { _ in }
  let visible = false
  init(file: URL) {}
  func restorePending() {}
  func discard() {}
  func suspend() {}
}

/// `/btw` asks a side question that is not saved to the conversation.
struct SideQuestionLaunch: Identifiable {
  let id = UUID()
  let text: String
  var submit = false
}

#if DEBUG
/// The iPhone's opening probe measures UIKit frames; the Mac records nothing.
enum ConversationOpeningMetrics {
  static func mark(_ name: String, id: String) {}
}
#endif
