import Foundation

/// Ported from Abacato's VoiceRecordingGesture; finishing requests transcription, never submission.
public struct VoiceRecordingGesture: Sendable {
  public enum State: Sendable { case idle, pressing, holding, locked, finished }
  /// `pressed`: a touch with the microphone already allowed records at once. `began`: permission is still unknown,
  /// and the system prompt would take the gesture.
  public enum Event: Sendable { case began, pressed, held, moved(CGSize), ended, cancelled }
  public enum Effect: Sendable { case none, startHolding, startLocked, handsFree, lock, finish, discard }
  /// Releasing before this is a tap and keeps recording hands-free. Without permission it is also the margin before
  /// holding, so a touch that slips off the button does not become a continuous recording.
  public static let holdDelay: TimeInterval = 0.3
  public static let cancelDistance: CGFloat = 100
  public static let lockDistance: CGFloat = 80
  public static let minimumDuration: TimeInterval = 1
  public private(set) var state = State.idle
  public private(set) var offset = CGSize.zero
  /// Recording since the touch and still within `holdDelay`.
  private var tapping = false
  public init() {}

  /// A hold released or interrupted before it is worth keeping as-is continues as a locked recording.
  public mutating func keepRecording() {
    state = .locked
    offset = .zero
  }

  public mutating func handle(_ event: Event) -> Effect {
    switch event {
    case .began:
      guard state == .idle else { return .none }
      state = .pressing
    case .pressed:
      guard state == .idle else { return .none }
      state = .holding
      tapping = true
      return .startHolding
    case .held:
      if state == .holding { tapping = false; return .none }
      guard state == .pressing else { return .none }
      state = .holding
      return .startHolding
    case .moved(let translation):
      if state == .pressing {
        if abs(translation.width) > 20 || abs(translation.height) > 20 {
          state = .finished
          return .discard
        }
      } else if state == .holding {
        let left = max(0, -translation.width), up = max(0, -translation.height)
        offset = CGSize(width: -min(left, Self.cancelDistance), height: -min(up, Self.lockDistance))
        if left >= Self.cancelDistance && left / Self.cancelDistance >= up / Self.lockDistance {
          state = .finished
          return .discard
        }
        if up >= Self.lockDistance { state = .locked; return .lock }
      }
    case .ended:
      if state == .pressing { state = .locked; return .startLocked }
      if state == .holding, tapping { keepRecording(); return .handsFree }
      if state == .holding { state = .finished; return .finish }
    case .cancelled:
      guard state == .pressing || state == .holding else { return .none }
      state = .finished
      return .discard
    }
    return .none
  }
}

/// Separates a transcription from the draft text around the insertion point with exactly one space where a word
/// touches it, never doubling existing whitespace and never splitting punctuation or brackets from their word.
/// `before`/`after` are the neighbouring characters (a token's attachment character counts as a word).
public enum DictationInsertion {
  public static func spaced(_ text: String, before: Character?, after: Character?) -> String {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = words.first, let last = words.last else { return "" }
    let prefix = before.map { !$0.isWhitespace && !"([{".contains($0) && !",.;:!?)]}…".contains(first) } ?? false
    let suffix = after.map { !$0.isWhitespace && !",.;:!?)]}…".contains($0) && !"([{".contains(last) } ?? false
    return (prefix ? " " : "") + words + (suffix ? " " : "")
  }
}

public enum VoiceRecordingAccessibility {
  public static func duration(_ time: TimeInterval) -> String {
    let seconds = max(0, Int(time)), minutes = seconds / 60, remainder = seconds % 60
    let tail = "\(remainder) \(remainder == 1 ? "segundo" : "segundos")"
    return minutes == 0 ? tail : "\(minutes) \(minutes == 1 ? "minuto" : "minutos") e \(tail)"
  }
}
