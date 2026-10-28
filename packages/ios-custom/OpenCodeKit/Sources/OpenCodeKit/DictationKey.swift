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

  /// Another key, a click or another modifier while the key is down: it is a modifier, not dictation.
  public mutating func interrupted() -> Action {
    guard case .pressed(_, let holding) = state else { return .none }
    state = .modifier
    return holding ? .discard : .none
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
