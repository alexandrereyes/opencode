import Foundation

/// Why a GPT Live call failed, was lost or ended: a category and, when there is one, the provider's error type and
/// code, the unreadable event's type or the kind of error. Never speech, a transcript or a message text.
public struct VoiceFailureReason: Equatable, Sendable {
  public let category: String
  public let code: String?

  public init(_ category: String, code: String? = nil) {
    self.category = category
    self.code = code.map(VoiceDiagnosticName.code).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// For logs: `service_error code=invalid_request_error/unknown_event`.
  public var summary: String { category + (code.map { " code=" + $0 } ?? "") }

  /// GPT Live sent `error`; `code` is its `type/code`.
  public static func service(_ code: String?) -> Self { Self("service_error", code: code) }
  /// An event the app could not read; `code` is its `type`.
  public static func invalidEvent(_ type: String?) -> Self { Self("invalid_event", code: type) }
  /// The llm-proxy refused to renew the call's lease.
  public static func leaseRefused(_ error: any Error) -> Self { Self("lease_refused", code: errorCode(error)) }
  /// The confirmed lease ran out with no renewal getting through.
  public static let leaseExpired = Self("lease_expired")
  /// An update could not go out on the data channel.
  public static let sendFailed = Self("send_failed")
  public static let iceFailed = Self("ice_failed")
  public static let peerFailed = Self("peer_failed")
  public static let dataChannelClosed = Self("data_channel_closed")
  public static let mediaReset = Self("media_services_reset")
  /// ICE disconnected and did not come back within the grace.
  public static let iceDisconnected = Self("ice_disconnected")
  /// A (re)connection attempt did not become ready in time.
  public static let attemptTimeout = Self("attempt_timeout")
  public static let networkChanged = Self("network_changed")
  public static let audioInterrupted = Self("audio_interrupted")
  public static let userEnd = Self("user_end")
  public static let recoveryExhausted = Self("recovery_exhausted")
  public static let microphoneDenied = Self("microphone_denied")
  public static let delegationOverflow = Self("delegation_overflow")
  public static func startFailed(_ error: any Error) -> Self { Self("start_failed", code: errorCode(error)) }
  public static func reconnectFailed(_ error: any Error) -> Self { Self("reconnect_failed", code: errorCode(error)) }

  /// The kind of an error, never its message: `http_503`, `url_-1009`, `invalid_answer`, `DecodingError`.
  public static func errorCode(_ error: any Error) -> String {
    switch error {
    case let wire as VoiceWireError:
      switch wire {
      case .invalidEvent: "invalid_event"
      case .invalidAnswer: "invalid_answer"
      case .oversized: "oversized"
      case .unavailable(let status): "http_\(status)"
      }
    case let url as URLError: "url_\(url.code.rawValue)"
    case let client as ClientError:
      switch client {
      case .http(let status): "http_\(status)"
      case .rpc: "rpc"
      case .incompatibleServer: "incompatible_server"
      case .locationNotFound: "location_not_found"
      case .operation: "operation"
      }
    case is CancellationError: "cancelled"
    default: String(describing: type(of: error))
    }
  }
}

/// Names as the server accepts them: no spaces or free text, bounded.
enum VoiceDiagnosticName {
  static func label(_ value: String) -> String {
    String(value.unicodeScalars.filter { allowed.contains($0) }.prefix(64).map(Character.init))
  }
  static func code(_ value: String) -> String {
    String(value.unicodeScalars.filter { allowed.contains($0) || $0 == "/" }.prefix(120).map(Character.init))
  }
  private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
}

/// The names of the last events of a call, oldest first: GPT Live's event types and the transport's states.
public struct VoiceEventTrail: Equatable, Sendable {
  public static let capacity = 24
  public private(set) var names: [String] = []
  public init() {}
  public mutating func record(_ name: String) {
    let label = VoiceDiagnosticName.label(name)
    names.append(label.isEmpty ? "unnamed" : label)
    if names.count > Self.capacity { names.removeFirst(names.count - Self.capacity) }
  }
}

/// One report to `custom.voice` → `diagnostics`, which the server logs as `Voice diagnostics`.
public struct VoiceDiagnostic: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case failed, lost, interrupted, ended, tolerated }
  public enum AppState: String, Codable, Sendable { case active, inactive, background }
  public struct App: Codable, Equatable, Sendable {
    public let state: AppState
    public let locked: Bool
    public init(state: AppState, locked: Bool) { self.state = state; self.locked = locked }
  }
  public struct Audio: Codable, Equatable, Sendable {
    public let category: String
    public let mode: String
    public let inputs: [String]
    public let outputs: [String]
    public let otherAudio: Bool?
    public init(category: String, mode: String, inputs: [String], outputs: [String], otherAudio: Bool? = nil) {
      self.category = String(category.prefix(120)); self.mode = String(mode.prefix(120))
      self.inputs = inputs.prefix(4).map(VoiceDiagnosticName.label); self.outputs = outputs.prefix(4).map(VoiceDiagnosticName.label)
      self.otherAudio = otherAudio
    }
  }

  public let kind: Kind
  public let reason: String
  public let code: String?
  public let platform: String
  public let build: String
  public let at: Double
  public let call: String?
  public let connectedSeconds: Double?
  public let phase: String
  public let recovering: Bool
  public let events: [String]
  public let app: App
  public let audio: Audio?
  public let network: String?

  public init(kind: Kind, reason: VoiceFailureReason, build: String, at: Date, call: UUID?, connectedSeconds: Double?,
    phase: String, recovering: Bool, events: VoiceEventTrail, app: App, audio: Audio?, network: String?) {
    self.kind = kind; self.reason = reason.category; self.code = reason.code
    #if os(macOS)
    platform = "macos"
    #else
    platform = "ios"
    #endif
    self.build = String(build.prefix(120)); self.at = (at.timeIntervalSince1970 * 1000).rounded()
    self.call = call?.uuidString; self.connectedSeconds = connectedSeconds.map { max(0, $0) }
    self.phase = VoiceDiagnosticName.label(phase); self.recovering = recovering; self.events = events.names
    self.app = app; self.audio = audio; self.network = network.map { String($0.prefix(120)) }
  }
}

/// Reports waiting for the server, kept on disk so a failure without network (or before the server knows the RPC)
/// still arrives on a later connection. Holds the newest 20.
public actor VoiceDiagnosticsOutbox {
  public static let limit = 20
  private let url: URL
  private var flushing = false

  public init(url: URL) { self.url = url }

  /// One per process, so concurrent flushes from the call and the event stream do not send a batch twice.
  public static let standard = VoiceDiagnosticsOutbox(url: (FileManager.default.urls(for: .applicationSupportDirectory,
    in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appending(path: "voice-diagnostics.json"))

  public func pending() -> [VoiceDiagnostic] {
    (try? JSONDecoder().decode([VoiceDiagnostic].self, from: Data(contentsOf: url))) ?? []
  }

  public func add(_ report: VoiceDiagnostic) {
    write(Array((pending() + [report]).suffix(Self.limit)))
  }

  /// Sends everything pending in one batch; keeps it when the send fails. Reports added meanwhile stay queued.
  public func flush(_ send: @Sendable ([VoiceDiagnostic]) async throws -> Void) async {
    guard !flushing else { return }
    let batch = pending()
    guard !batch.isEmpty else { return }
    flushing = true
    defer { flushing = false }
    do { try await send(batch) } catch { return }
    write(pending().filter { !batch.contains($0) })
  }

  private func write(_ reports: [VoiceDiagnostic]) {
    if reports.isEmpty { try? FileManager.default.removeItem(at: url); return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(reports).write(to: url, options: .atomic)
  }
}

extension OpenCodeClient {
  public func voiceDiagnostics(_ reports: [VoiceDiagnostic]) async throws {
    struct Input: Encodable { let events: [VoiceDiagnostic] }
    let _: JSONValue = try await rpc("custom.voice", "diagnostics", input: Input(events: reports), timeout: 8)
  }
}
