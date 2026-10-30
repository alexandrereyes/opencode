import Foundation

/// The Mac's right Option key as a dictation key (keyCode 61). A tap starts hands-free recording and the next tap
/// stops it; held past `holdDelay`, it records while down and stops on release (push-to-talk). The key is never
/// taken while it is a modifier: a press with another modifier is ignored, and any other key or click while it is
/// down gives it back (discarding a recording the hold started).
public struct DictationKeyGesture: Sendable, Equatable {
  public static let keyCode: UInt16 = 61
  /// How long the key stays down before it starts push-to-talk.
  public static let holdDelay: Duration = .milliseconds(250)

  public enum Action: Sendable, Equatable {
    case none
    /// Start recording at once (the hold); `release` ends it.
    case begin
    /// The hold ended: stop and transcribe (a hold shorter than a dictation keeps recording hands-free).
    case release
    /// A tap while idle: start hands-free recording.
    case start
    /// A tap while recording: stop and transcribe.
    case finish
    /// The key turned out to be a modifier after the hold had started a recording.
    case discard
    /// Esc during a dictation: stop and throw it away, with nothing transcribed.
    case cancel
    /// ⌥⌘E during a dictation: turn its AI review on or off (during the review: use the original text).
    case toggleRevision
  }

  private enum State: Sendable, Equatable {
    case idle
    case pressed(recording: Bool, holding: Bool)
    case modifier
  }

  private var state = State.idle

  public init() {}

  /// The key went down; `recording` is the composer's state, `otherModifiers` whether ⌘, ⌃, ⇧ or the left ⌥ are
  /// held too.
  public mutating func press(recording: Bool, otherModifiers: Bool) {
    state = otherModifiers ? .modifier : .pressed(recording: recording, holding: false)
  }

  /// `holdDelay` passed with the key still down and nothing else pressed.
  public mutating func held() -> Action {
    guard case .pressed(false, false) = state else { return .none }
    state = .pressed(recording: false, holding: true)
    return .begin
  }

  /// Another modifier went down or up while the key is down. ⌘ during a hold waits for its key, since ⌥⌘E
  /// (`toggleRevision`) keeps the hold; before the hold, and for any other modifier, the key is a modifier.
  public mutating func modifier(command: Bool) -> Action {
    if command, case .pressed(_, true) = state { return .none }
    return interrupted()
  }

  /// ⌥⌘E: the dictation's review switch, with or without the key down; a hold goes on.
  public func toggleRevision(dictating: Bool) -> Action { dictating ? .toggleRevision : .none }

  /// Another key, a click or another modifier while the key is down: it is a modifier, not dictation.
  public mutating func interrupted() -> Action {
    guard case .pressed(_, let holding) = state else { return .none }
    state = .modifier
    return holding ? .discard : .none
  }

  /// Esc. With a dictation under way (`dictating`: recording, by a tap or a hold, or transcribing) it cancels it and
  /// Esc does nothing else; the key, if still down, then gives nothing on release. Otherwise Esc keeps its meaning
  /// and, with the key down, makes it a modifier like any other key.
  public mutating func escape(dictating: Bool) -> Action {
    if down { state = .modifier }
    return dictating ? .cancel : .none
  }

  public mutating func release() -> Action {
    defer { state = .idle }
    switch state {
    case .idle, .modifier: return .none
    case .pressed(true, _): return .finish
    case .pressed(false, true): return .release
    case .pressed(false, false): return .start
    }
  }

  public var down: Bool { state != .idle }
}
