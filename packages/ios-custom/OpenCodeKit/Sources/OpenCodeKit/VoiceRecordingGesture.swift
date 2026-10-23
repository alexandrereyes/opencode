import Foundation

/// Ported from Abacato's VoiceRecordingGesture; finishing requests transcription, never submission.
public struct VoiceRecordingGesture: Sendable {
  public enum State: Sendable { case idle, pressing, holding, locked, finished }
  public enum Event: Sendable { case began, held, moved(CGSize), ended, cancelled }
  public enum Effect: Sendable { case none, startHolding, startLocked, lock, finish, discard }
  public static let holdDelay: TimeInterval = 0.22
  public static let cancelDistance: CGFloat = 100
  public static let lockDistance: CGFloat = 80
  public static let minimumDuration: TimeInterval = 1
  public private(set) var state = State.idle
  public private(set) var offset = CGSize.zero
  public init() {}

  public mutating func handle(_ event: Event) -> Effect {
    switch event {
    case .began:
      guard state == .idle else { return .none }
      state = .pressing
    case .held:
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
      if state == .holding { state = .finished; return .finish }
    case .cancelled:
      guard state == .pressing || state == .holding else { return .none }
      state = .finished
      return .discard
    }
    return .none
  }
}

public enum VoiceRecordingAccessibility {
  public static func duration(_ time: TimeInterval) -> String {
    let seconds = max(0, Int(time)), minutes = seconds / 60, remainder = seconds % 60
    let tail = "\(remainder) \(remainder == 1 ? "segundo" : "segundos")"
    return minutes == 0 ? tail : "\(minutes) \(minutes == 1 ? "minuto" : "minutos") e \(tail)"
  }
}
