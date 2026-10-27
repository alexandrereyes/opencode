import Foundation

/// Fixed heights of the "Agentes" Live Activity. The system proposes an unbounded height to the expanded Dynamic
/// Island and clips whatever passes its limit, so neither presentation measures itself (`ViewThatFits` picked a
/// layout that was then cut on device). Every block has a fixed frame of these heights, and the row count and Lock
/// Screen density are computed from the state.
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
    let rows = min(state.sessions.count, islandMaxRows, fitting)
    let base = islandHeader + (rows > 0 ? islandGap + CGFloat(rows) * islandRow : 0)
    let hidden = state.sessions.count - rows
    let more = hidden > 0 && base + islandMore <= islandCeiling ? hidden : nil
    return Island(rows: rows, more: more, height: base + (more == nil ? 0 : islandMore))
  }

  // MARK: Lock Screen

  /// The system may truncate a Live Activity taller than 160 points; keep a small margin below it.
  public static let lockLimit: CGFloat = 160
  public static let lockCeiling: CGFloat = 156

  public enum Density: CaseIterable, Sendable {
    /// The approved mock: header row, activity on its own line, two-line pending rows.
    case regular
    /// Activity beside the project, one-line pending rows.
    case compact
    /// Also without the header row (mascot and host move to the footer) and at most two pending rows.
    case tight
  }

  public struct Lock: Sendable {
    public let padding: CGFloat
    public let spacing: CGFloat
    public let header: CGFloat?
    public let focusLine: CGFloat = 32
    public let activity: CGFloat?
    public let progress: CGFloat = 13
    public let focusSpacing: CGFloat = 4
    public let pendingPadding: CGFloat
    public let pendingTitle: CGFloat = 13
    public let pendingSpacing: CGFloat
    public let singleRow: CGFloat
    public let singleText: CGFloat?
    public let listRow: CGFloat
    public let pendingRows: Int
    public let footer: CGFloat = 14
    public let empty: CGFloat = 16

    public init(_ density: Density) {
      switch density {
      case .regular:
        padding = 10; spacing = 7; header = 16; activity = 15
        pendingPadding = 7; pendingSpacing = 4; singleRow = 30; singleText = 15; listRow = 30; pendingRows = 3
      case .compact:
        padding = 10; spacing = 6; header = 16; activity = nil
        pendingPadding = 5; pendingSpacing = 3; singleRow = 24; singleText = nil; listRow = 18; pendingRows = 3
      case .tight:
        padding = 7; spacing = 4; header = nil; activity = nil
        pendingPadding = 4; pendingSpacing = 2; singleRow = 24; singleText = nil; listRow = 18; pendingRows = 2
      }
    }

    public func focusHeight(_ focus: AgentsState.Focus) -> CGFloat {
      focusLine + (activity != nil && focus.activity != nil ? focusSpacing + activity! : 0)
        + (focus.progress != nil ? focusSpacing + progress : 0)
    }

    public func pendingHeight(_ state: AgentsState) -> CGFloat {
      let body: CGFloat = state.pendingList
        ? CGFloat(min(state.attention.count, pendingRows)) * (pendingSpacing + listRow)
        : pendingSpacing + singleRow
          + (singleText != nil && state.attention.first?.text != nil ? pendingSpacing + singleText! : 0)
      return 2 * pendingPadding + pendingTitle + body
    }

    public func height(_ state: AgentsState) -> CGFloat {
      var blocks = [CGFloat]()
      if let header { blocks.append(header) }
      if let focus = state.focus { blocks.append(focusHeight(focus)) }
      if !state.attention.isEmpty { blocks.append(pendingHeight(state)) }
      if state.focus == nil && state.attention.isEmpty && state.footer.isEmpty { blocks.append(empty) }
      blocks.append(footer)
      return 2 * padding + blocks.reduce(0, +) + spacing * CGFloat(blocks.count - 1)
    }
  }

  /// The first density whose computed height fits; `tight` always fits (at most focus and two pending rows).
  public static func lockDensity(_ state: AgentsState) -> Density {
    Density.allCases.first { Lock($0).height(state) <= lockCeiling } ?? .tight
  }
}
