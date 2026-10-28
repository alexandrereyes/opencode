import Foundation

/// What the reading rules need to know about one transcript item: its identity, the text part and message it
/// belongs to (nil for controls and request cards) and whether it is a prompt.
public struct TranscriptItemIdentity: Sendable, Equatable {
  public var id: String
  public var partID: String?
  public var message: String?
  public var sticky: Bool
  public init(id: String, partID: String? = nil, message: String? = nil, sticky: Bool = false) {
    self.id = id
    self.partID = partID
    self.message = message
    self.sticky = sticky
  }
}

/// Where an item's message starts: the index of its first item and the padding above that item that belongs
/// to the message (reading positions measure from the message's top).
public struct TranscriptOwner: Sendable, Equatable {
  public var start: Int
  public var inset: Double
  public init(start: Int, inset: Double) {
    self.start = start
    self.inset = inset
  }
}

/// The reading rules shared by the transcripts (the iPhone's collection view and the Mac's scroll view), apart
/// from any view: the latest place, the reader's anchor for the next change, where the anchor continues when
/// its item is replaced, and which item owns each message.
extension TranscriptGeometry {
  /// The end at the bottom edge, or the spacer prompt at the top while its answer is shorter than the viewport.
  public func latestOffset(viewport: Double, maximum: Double) -> Double {
    var offset = contentEnd - viewport
    if let id = spacerPrompt, let index = index(of: id) { offset = max(offset, tops[index]) }
    return min(max(0, offset), max(0, maximum))
  }

  /// The anchor that keeps what the reader sees still through the next change. Not the history control at the
  /// very top (older pages land below it), and not an item that was never measured while a measured one is on
  /// screen below it: rows measured while scrolling into history then keep everything already shown in place.
  public func stableAnchor(visibleTop: Double, viewport: Double, measured: [Bool], control: String? = nil) -> Anchor? {
    guard var anchor = anchor(visibleTop: visibleTop) else { return nil }
    if let control, anchor.id == control, count > 1 {
      anchor = Anchor(id: entries[1].id, screenY: tops[1] - visibleTop)
    }
    guard let index = index(of: anchor.id), measured.indices.contains(index), !measured[index] else { return anchor }
    let bottom = visibleTop + viewport
    guard let shown = (index..<count).first(where: { measured.indices.contains($0) && measured[$0] && tops[$0] < bottom })
    else { return anchor }
    return Anchor(id: entries[shown].id, screenY: tops[shown] - visibleTop)
  }

  /// The anchor after an update. When its item is replaced (a placeholder by the blocks its parse produced, a
  /// block split by a newer parse), the reader's place continues in what replaced it: the part's first new item,
  /// then the message's, then the next item that survived, each at the same screen position. `self` is the
  /// geometry of `old`.
  public func continued(_ anchor: Anchor, from old: [TranscriptItemIdentity], to next: [TranscriptItemIdentity])
    -> Anchor?
  {
    if next.contains(where: { $0.id == anchor.id }) { return anchor }
    guard let index = old.firstIndex(where: { $0.id == anchor.id }) else { return nil }
    let item = old[index]
    if let part = item.partID, let replacement = next.first(where: { $0.partID == part }) {
      return Anchor(id: replacement.id, screenY: anchor.screenY)
    }
    if let message = item.message, let replacement = next.first(where: { $0.message == message }) {
      return Anchor(id: replacement.id, screenY: anchor.screenY)
    }
    let survivors = Set(next.map(\.id))
    guard let following = old.indices.dropFirst(index + 1).first(where: { survivors.contains(old[$0].id) }),
      following < count, index < count else { return nil }
    return Anchor(id: old[following].id, screenY: anchor.screenY + tops[following] - tops[index])
  }

  /// Each item's owner: consecutive items of one message share the first; a message that does not start with
  /// a prompt owns `inset` points of padding above its first item.
  public static func owners(_ items: [TranscriptItemIdentity], inset: Double = 10) -> [TranscriptOwner] {
    var result: [TranscriptOwner] = []
    var start = 0
    for (index, item) in items.enumerated() {
      if index == 0 || item.message == nil || item.message != items[index - 1].message { start = index }
      result.append(TranscriptOwner(start: start, inset: items[start].sticky || items[start].message == nil ? 0 : inset))
    }
    return result
  }

  /// Content position of the top of the message that owns the item.
  public func messageTop(_ index: Int, owners: [TranscriptOwner]) -> Double {
    let owner = owners.indices.contains(index) ? owners[index] : TranscriptOwner(start: index, inset: 0)
    return tops[owner.start] - owner.inset
  }
}

/// Following the end while an answer arrives, on a desktop transcript: the end stays in view while the reader is
/// there, scrolling up stops it at once, and scrolling (or jumping) back to the end resumes it. Explicit navigation
/// elsewhere (search, a quote, a pinned prompt) stops it too.
public struct TranscriptFollow: Sendable, Equatable {
  public private(set) var following = false
  /// The reader's wheel, trackpad or scroller owns the offset.
  public private(set) var interacting = false
  public init(following: Bool = false) { self.following = following }

  /// The transcript opened at the end (`followTail`) or at a saved passage.
  public mutating func opened(atEnd: Bool) { following = atEnd }
  public mutating func began() {
    interacting = true
    following = false
  }
  /// The reader's scrolling settled `distance` points above the latest place.
  public mutating func settled(distance: Double) {
    interacting = false
    if distance <= 2 { following = true }
  }
  public mutating func navigated(toLatest: Bool) { following = toLatest }
  /// Whether content that grew should keep the latest place in view.
  public var keepsLatest: Bool { following && !interacting }
}

/// The transcript's keyboard: Page Up/Down and space page by the viewport less a line of overlap, ⌘↑ and Home go
/// to the top of what is loaded, ⌘↓ and End to the latest place, the arrows move a line.
public enum TranscriptScrollKey: Sendable, Equatable {
  case pageUp, pageDown, top, latest, lineUp, lineDown

  public static let overlap = 60.0
  public static let line = 40.0

  public func target(visibleTop: Double, viewport: Double, latest: Double) -> Double {
    let page = max(Self.line, viewport - Self.overlap)
    return switch self {
    case .pageUp: max(0, visibleTop - page)
    case .pageDown: min(latest, visibleTop + page)
    case .top: 0
    case .latest: latest
    case .lineUp: max(0, visibleTop - Self.line)
    case .lineDown: min(latest, visibleTop + Self.line)
    }
  }
}
