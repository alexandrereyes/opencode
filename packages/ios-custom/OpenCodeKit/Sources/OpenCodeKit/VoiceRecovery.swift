import Foundation

/// Limits for keeping one voice conversation alive across network loss. Tests inject shorter values;
/// the lease margin is deliberately not configurable.
public struct VoiceRecoveryPolicy: Sendable, Equatable {
  /// Audio stops this long before the proxy lease expires, whatever the network does.
  public static let leaseMargin: TimeInterval = 10
  /// Interval between renewals of a healthy lease.
  public var renewal: TimeInterval
  /// Interval between renewal retries after a transient failure.
  public var renewalRetry: TimeInterval
  /// Time WebRTC gets to restore a disconnected peer on its own, on the same network, before the call is rebuilt.
  /// Repeated disconnections inside it do not extend it.
  public var mediaGrace: TimeInterval
  /// What is left of that grace once the network comes back on other interfaces (Wi-Fi to 5G): WebRTC may move
  /// the call to a candidate pair it already has there before the call is rebuilt.
  public var handoverGrace: TimeInterval
  /// Overall limit, from the first loss, to restore audio.
  public var window: TimeInterval
  /// Delay before each rebuilt call; its count is the attempt limit.
  public var backoff: [TimeInterval]
  /// Deadline for one rebuilt call to become ready.
  public var attemptTimeout: TimeInterval
  /// Interval between network checks while offline.
  public var networkPoll: TimeInterval

  public init(renewal: TimeInterval = 5, renewalRetry: TimeInterval = 1, mediaGrace: TimeInterval = 15,
              handoverGrace: TimeInterval = 3, window: TimeInterval = 120, backoff: [TimeInterval] = [1, 2, 4, 8, 15, 15],
              attemptTimeout: TimeInterval = 20, networkPoll: TimeInterval = 0.25) {
    self.renewal = renewal; self.renewalRetry = renewalRetry; self.mediaGrace = mediaGrace
    self.handoverGrace = handoverGrace; self.window = window; self.backoff = backoff
    self.attemptTimeout = attemptTimeout; self.networkPoll = networkPoll
  }
}

/// Local validity of the proxy lease, measured on the monotonic clock from the start of the confirming request.
public struct VoiceLeaseClock: Sendable, Equatable {
  public private(set) var validUntil: TimeInterval = 0
  public init() {}

  /// Records a confirmed lease. False when its remaining validity is already inside the safety margin.
  public mutating func confirm(_ lease: VoiceLease, requestedAt: TimeInterval, now: TimeInterval) -> Bool {
    validUntil = requestedAt + lease.remaining - VoiceRecoveryPolicy.leaseMargin
    return validUntil > now
  }
  public func valid(at now: TimeInterval) -> Bool { now < validUntil }

  /// Only an unreachable or overloaded server is retried: a network error, a timeout, 408, 429 or any 5xx, from the
  /// proxy or the OpenCode server. An explicit refusal (another 4xx), a malformed lease or another call's lease
  /// keeps ending the call immediately.
  public static func isTransient(_ error: any Error) -> Bool {
    if let error = error as? URLError { return error.code != .cancelled }
    if case VoiceWireError.unavailable(let status) = error { return transient(status) }
    if case ClientError.http(let status) = error { return transient(status) }
    return false
  }
  private static func transient(_ status: Int) -> Bool { status == 408 || status == 429 || (500...599).contains(status) }
}

/// Attempt and deadline bookkeeping for rebuilding a lost call.
public struct VoiceRecovery: Sendable, Equatable {
  public let policy: VoiceRecoveryPolicy
  public private(set) var lostAt: TimeInterval?
  public private(set) var attempts = 0
  public init(policy: VoiceRecoveryPolicy = .init()) { self.policy = policy }

  public var active: Bool { lostAt != nil }
  /// The first loss starts the window; later losses while recovering keep it.
  public mutating func lose(at now: TimeInterval) {
    guard lostAt == nil else { return }
    lostAt = now; attempts = 0
  }
  public mutating func restore() { lostAt = nil; attempts = 0 }
  public func remaining(at now: TimeInterval) -> TimeInterval {
    lostAt.map { max(0, $0 + policy.window - now) } ?? policy.window
  }
  /// Delay before the next attempt, or nil when attempts or the window are exhausted.
  public mutating func next(at now: TimeInterval) -> TimeInterval? {
    guard lostAt != nil, attempts < policy.backoff.count else { return nil }
    let delay = policy.backoff[attempts]
    guard delay < remaining(at: now) else { return nil }
    attempts += 1
    return delay
  }
}

/// Network reachability as the voice call needs it: whether any route exists and which interfaces carry it.
public struct VoicePath: Sendable, Equatable {
  public var satisfied: Bool
  public var interfaces: [String]
  public init(satisfied: Bool, interfaces: [String] = []) {
    self.satisfied = satisfied; self.interfaces = interfaces
  }
}

/// Coarse call state for compact surfaces: Live Activity today, CarPlay voice control later.
public enum VoiceIndicator: String, CaseIterable, Sendable {
  case connecting, listening, speaking, working, interrupted, reconnecting, offline, failed

  public init?(_ state: VoiceState) {
    switch state.phase {
    case .idle: return nil
    case .connecting: self = .connecting
    case .listening: self = state.masterWorking ? .working : .listening
    case .speaking: self = .speaking
    case .interrupted: self = .interrupted
    case .reconnecting: self = .reconnecting
    case .offline: self = .offline
    case .failed: self = .failed
    }
  }
  public var title: String {
    switch self {
    case .connecting: "Conectando voz…"
    case .listening: "Ouvindo"
    case .speaking: "Falando"
    case .working: "Sessão mestra trabalhando…"
    case .interrupted: "Áudio interrompido"
    case .reconnecting: "Reconectando…"
    case .offline: "Sem conexão"
    case .failed: "Voz indisponível"
    }
  }
  /// Short variant for narrow surfaces such as a CarPlay overlay.
  public var shortTitle: String {
    switch self {
    case .connecting: "Conectando"
    case .working: "Mestra trabalhando"
    case .interrupted: "Interrompido"
    case .reconnecting: "Reconectando"
    case .failed: "Indisponível"
    default: title
    }
  }
  public var symbol: String {
    switch self {
    case .connecting, .reconnecting: "antenna.radiowaves.left.and.right"
    case .listening: "mic.fill"
    case .speaking: "waveform"
    case .working: "brain"
    case .interrupted: "pause.fill"
    case .offline: "wifi.slash"
    case .failed: "exclamationmark.triangle.fill"
    }
  }
  /// Whether a surface should animate this state.
  public var animates: Bool { [.connecting, .listening, .speaking, .working, .reconnecting].contains(self) }
}
