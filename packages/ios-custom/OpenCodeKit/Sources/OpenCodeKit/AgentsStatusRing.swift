import Foundation

/// The state ring shared by every summary of the agents: the Live Activity (Lock Screen card, minimal Dynamic Island,
/// the Apple Watch Smart Stack card), the watch complications and the watch Painel (rev. 2026-10-30).
///
/// One segment per state with sessions, proportional to its count, clockwise in this order and in the legends'
/// colors: `pergunta` (accent), `permissão` (warning), `com erro` (error), `não lida` (primary), `trabalhando`
/// (success, or the legends' muted textSecondary while something needs Alexandre), and, only from an older backend
/// without `unread`, the recently finished sessions (textSecondary, dimmed). Failures keep their own red segment:
/// they need him like a request, but they are not a question to answer and the legends already show them apart.
///
/// Each top-level session counts once, in the backend's precedence question > permission > failed > working > unread
/// (a session is unread only when it is not working and needs nothing else), so the segments never add up to more
/// than the sessions. The centre keeps the rule of the cards (Option A, 29/10): `forYou` ("para você": questions +
/// permissions + failures + unread), which is exactly the colored segments other than `trabalhando`; with nothing for
/// him, the sessions working ("ativas"). Nothing at all: no segment, only the neutral track.
public struct AgentsStatusRing: Equatable, Sendable {
  public enum State: String, Sendable {
    case question, permission, failed, unread, working, finished
  }

  public struct Segment: Equatable, Sendable {
    public let state: State
    public let count: Int
    public let role: ThemeRole
    /// Drawn at reduced opacity (the recently finished fallback).
    public let dim: Bool
  }

  /// One stroke, in degrees of SwiftUI's clockwise coordinates (0° is 3 o'clock, 90° is 6 o'clock).
  public struct Arc: Equatable, Sendable {
    public let role: ThemeRole
    public let dim: Bool
    public let from: Double
    public let to: Double
  }

  /// Non-empty states, in drawing order.
  public let segments: [Segment]
  /// The centre's number: `forYou`, or the sessions working when nothing needs Alexandre.
  public let number: Int
  /// The number counts what needs Alexandre (`para você`).
  public let forYou: Bool

  public init(counts: AgentsState.Counts?) {
    let forYou = counts?.forYou ?? 0
    self.forYou = forYou > 0
    number = forYou > 0 ? forYou : counts?.working ?? 0
    guard let counts else {
      segments = []
      return
    }
    let all = [
      Segment(state: .question, count: counts.question, role: .accent, dim: false),
      Segment(state: .permission, count: counts.permission, role: .warning, dim: false),
      Segment(state: .failed, count: counts.failed, role: .error, dim: false),
      Segment(state: .unread, count: counts.unread ?? 0, role: .primary, dim: false),
      Segment(state: .working, count: counts.working, role: forYou > 0 ? .textSecondary : .success, dim: false),
      Segment(state: .finished, count: counts.unread == nil ? counts.idle : 0, role: .textSecondary, dim: true),
    ]
    segments = all.filter { $0.count > 0 }
  }

  /// The sessions the segments stand for.
  public var total: Int { segments.reduce(0) { $0 + $1.count } }
  /// `para você`, `ativa` or `ativas`.
  public var label: String { forYou ? "para você" : number == 1 ? "ativa" : "ativas" }

  /// The strokes: `opening` degrees left open at the bottom (the watch's mascot sits there) or 0 for a closed circle
  /// from 12 o'clock; `spacing` degrees between neighbouring segments (a closed ring also has one at 12 o'clock). A
  /// single segment of a closed ring closes the circle. Empty when nothing counts: the view draws the track.
  public func arcs(opening: Double = 0, spacing: Double) -> [Arc] {
    let total = Double(self.total)
    guard total > 0 else { return [] }
    let closed = opening <= 0
    let origin = closed ? -90 : 90 + opening / 2
    let sweep = closed ? 360 : 360 - opening
    if closed && segments.count == 1 {
      return [Arc(role: segments[0].role, dim: segments[0].dim, from: origin, to: origin + 360)]
    }
    var start = 0.0
    return segments.enumerated().map { index, segment in
      let end = start + Double(segment.count) / total
      defer { start = end }
      let before = closed || index > 0 ? spacing / 2 : 0
      let after = closed || index < segments.count - 1 ? spacing / 2 : 0
      let from = origin + start * sweep + before
      // A segment smaller than the spacing still shows, as a dot of the round cap.
      return Arc(role: segment.role, dim: segment.dim, from: from, to: max(from, origin + end * sweep - after))
    }
  }

  /// The whole drawable sweep, for the neutral track.
  public static func track(opening: Double = 0) -> (from: Double, to: Double) {
    opening <= 0 ? (-90, 270) : (90 + opening / 2, 450 - opening / 2)
  }
}
