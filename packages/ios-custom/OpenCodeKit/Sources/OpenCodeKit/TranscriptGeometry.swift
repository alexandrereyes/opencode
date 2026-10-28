import Foundation

/// Vertical geometry of the conversation transcript: item positions from heights and gaps, the pinned prompt,
/// the reading anchor and the trailing space that lets a just-sent prompt reach the top.
///
/// Coordinates are content points from the top of the scrollable content. `visibleTop` is the content offset of
/// the viewport's top edge. Prompts (`sticky`) start sections; the prompt of the section crossing the top edge is
/// pinned there until the next prompt pushes it up.
public struct TranscriptGeometry: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    public var id: String
    /// Space above the item, outside its frame.
    public var gap: Double
    public var height: Double
    public var sticky: Bool
    public init(id: String, gap: Double, height: Double, sticky: Bool = false) {
      self.id = id
      self.gap = gap
      self.height = height
      self.sticky = sticky
    }
  }

  /// An item and where its top edge sits on screen, relative to the viewport's top edge.
  public struct Anchor: Sendable, Equatable {
    public var id: String
    public var screenY: Double
    public init(id: String, screenY: Double) {
      self.id = id
      self.screenY = screenY
    }
  }

  public struct Pinned: Sendable, Equatable {
    public let index: Int
    /// Content position of the pinned prompt's top edge.
    public let y: Double
  }

  public private(set) var entries: [Entry] = []
  public private(set) var tops: [Double] = []
  public var topPadding: Double
  public var bottomPadding: Double
  /// The prompt that may rise to the top: the trailing space never lets the content end above it.
  public var spacerPrompt: String?
  private var positions: [String: Int] = [:]

  public init(topPadding: Double = 0, bottomPadding: Double = 0) {
    self.topPadding = topPadding
    self.bottomPadding = bottomPadding
  }

  public var count: Int { entries.count }

  public mutating func replace(_ entries: [Entry]) {
    self.entries = entries
    positions = Dictionary(entries.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    recompute(from: 0)
  }

  /// Changes one height; later positions shift by the difference. Returns the difference.
  @discardableResult public mutating func setHeight(_ height: Double, at index: Int) -> Double {
    let delta = height - entries[index].height
    guard delta != 0 else { return 0 }
    entries[index].height = height
    for later in (index + 1)..<max(index + 1, tops.count) { tops[later] += delta }
    return delta
  }

  public func index(of id: String) -> Int? { positions[id] }
  public func frame(_ index: Int) -> (top: Double, bottom: Double) { (tops[index], tops[index] + entries[index].height) }

  /// The end of the last item, including the bottom padding but not the trailing space.
  public var contentEnd: Double {
    guard let last = entries.indices.last else { return topPadding + bottomPadding }
    return tops[last] + entries[last].height + bottomPadding
  }

  /// Extra space after the content so the spacer prompt can sit at the top of a viewport of this height.
  public func spacer(viewport: Double) -> Double {
    guard let id = spacerPrompt, let index = positions[id] else { return 0 }
    return max(0, tops[index] + viewport - contentEnd)
  }

  public func contentHeight(viewport: Double) -> Double { contentEnd + spacer(viewport: viewport) }

  /// The first index whose frame (with its gap) reaches below `y`.
  public func firstIndex(below y: Double) -> Int {
    var low = 0
    var high = entries.count
    while low < high {
      let middle = (low + high) / 2
      if tops[middle] + entries[middle].height <= y { low = middle + 1 } else { high = middle }
    }
    return low
  }

  /// The prompt pinned at `visibleTop`, if a section crosses the top edge.
  public func pinned(visibleTop: Double) -> Pinned? {
    let first = firstIndex(below: visibleTop)
    guard first < entries.count else { return nil }
    // The section owning the top edge starts at the last prompt at or above it; a prompt exactly at the top
    // edge is already in its pinned place.
    guard let start = (0...first).reversed().first(where: { entries[$0].sticky }), tops[start] <= visibleTop
    else { return nil }
    let next = entries.indices.dropFirst(start + 1).first { entries[$0].sticky }
    let limit = next.map { tops[$0] - entries[start].height } ?? .infinity
    return Pinned(index: start, y: min(visibleTop, limit))
  }

  /// Points from the viewport's top edge that the pinned prompt covers.
  public func usableTop(visibleTop: Double) -> Double {
    guard let pinned = pinned(visibleTop: visibleTop) else { return 0 }
    return max(0, pinned.y + entries[pinned.index].height - visibleTop)
  }

  /// The item under the reading line (just below the pinned prompt), or the next one when the line falls in
  /// a gap. A pinned prompt is never the anchor: its screen position is not the reader's place.
  public func anchor(visibleTop: Double) -> Anchor? {
    guard !entries.isEmpty else { return nil }
    let pinned = pinned(visibleTop: visibleTop)
    let line = visibleTop + usableTop(visibleTop: visibleTop)
    var index = firstIndex(below: line)
    if index == pinned?.index { index += 1 }
    guard index < entries.count else { return nil }
    return Anchor(id: entries[index].id, screenY: tops[index] - visibleTop)
  }

  /// The visible top that puts the anchor's item back at its screen position.
  public func visibleTop(for anchor: Anchor) -> Double? {
    positions[anchor.id].map { tops[$0] - anchor.screenY }
  }

  private mutating func recompute(from start: Int) {
    if tops.count != entries.count { tops = Array(repeating: 0, count: entries.count) }
    var y = start == 0 ? topPadding : tops[start - 1] + entries[start - 1].height
    for index in start..<entries.count {
      y += entries[index].gap
      tops[index] = y
      y += entries[index].height
    }
  }
}
