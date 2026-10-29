import Foundation

/// Fixed heights of the "Agentes" Live Activity. The system proposes an unbounded height to the expanded Dynamic
/// Island and clips whatever passes its limit, so no presentation measures itself (`ViewThatFits` picked a layout
/// that was then cut on device). Every block has a fixed frame of these heights; the island's row count is computed
/// from the state.
public enum AgentsLayout {
  // MARK: Expanded Dynamic Island

  /// Measured with a ruler in the bottom region on iPhone 17 Pro and 17 Pro Max (iOS 27): the region always gets
  /// 110 points below the camera row, and the island's rounded bottom corners clip its sides from about 95 points.
  /// Apple documents 84–160 points for the whole expanded presentation, camera row included.
  public static let islandRegion: CGFloat = 110
  /// Content never goes past this, keeping clear of the corners.
  public static let islandCeiling: CGFloat = 96
  public static let islandHeader: CGFloat = 18
  public static let islandGap: CGFloat = 4
  public static let islandRow: CGFloat = 20
  public static let islandMore: CGFloat = 12
  /// The contract caps the expanded island at three rows.
  public static let islandMaxRows = 3

  public struct Island: Equatable, Sendable {
    public let rows: Int
    /// Sessions left out, shown as `+N` only when that line fits under the ceiling too.
    public let more: Int?
    public let height: CGFloat
  }

  public static func island(_ state: AgentsState) -> Island {
    let fitting = Int((islandCeiling - islandHeader - islandGap) / islandRow)
    let rows = min(state.islandRows.count, islandMaxRows, fitting)
    let base = islandHeader + (rows > 0 ? islandGap + CGFloat(rows) * islandRow : 0)
    let hidden = state.islandTotal - rows
    let more = hidden > 0 && base + islandMore <= islandCeiling ? hidden : nil
    return Island(rows: rows, more: more, height: base + (more == nil ? 0 : islandMore))
  }

  // MARK: Lock Screen

  /// Apple: the system may truncate a Live Activity taller than 160 points.
  public static let lockLimit: CGFloat = 160
  public static let lockPadding: CGFloat = 10
  public static let lockHeader: CGFloat = 16
  public static let lockGap: CGFloat = 6
  /// A hairline inside a one-point frame, so the height stays whole.
  public static let lockRule: CGFloat = 1
  public static let lockRing: CGFloat = 72
  public static let lockRingWidth: CGFloat = 7
  public static let lockCounter: CGFloat = 18
  /// Counter lines fit beside the ring: four of `lockCounter` fill `lockRing`.
  public static let lockMaxCounters = 4
  public static let lockAttention: CGFloat = 16
  /// Width of `há N min.` in the attention line, enough for "há 59 min." at 12 points.
  public static let lockAgo: CGFloat = 64

  /// Header, rule, ring and counters, plus a rule and the attention line when something needs Alexandre: 121 or 150
  /// points.
  public static func lockHeight(_ state: AgentsState) -> CGFloat {
    let body = lockHeader + 2 * lockGap + lockRule + lockRing
    return 2 * lockPadding + body + (state.attentionLine == nil ? 0 : 2 * lockGap + lockRule + lockAttention)
  }
}
