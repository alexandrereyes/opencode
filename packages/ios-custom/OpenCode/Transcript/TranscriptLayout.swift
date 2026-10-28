import OpenCodeKit
import UIKit

final class TranscriptLayoutAttributes: UICollectionViewLayoutAttributes {
  // Attributes are compared from `isEqual`, which UIKit declares nonisolated; they are only ever used on main.
  /// A prompt pinned under the header with content passing under it, which draws a fade below itself.
  nonisolated(unsafe) var pinned = false
  /// How far the item starts below its message's top.
  nonisolated(unsafe) var messageOffset: CGFloat = 0
  override func copy(with zone: NSZone? = nil) -> Any {
    let copy = super.copy(with: zone) as! TranscriptLayoutAttributes
    copy.pinned = pinned
    copy.messageOffset = messageOffset
    return copy
  }
  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TranscriptLayoutAttributes, other.pinned == pinned,
      other.messageOffset == messageOffset else { return false }
    return super.isEqual(object)
  }
}

@MainActor protocol TranscriptLayoutDelegate: AnyObject {
  /// A cell reported its real height for the current width.
  func layout(_ layout: TranscriptLayout, measured height: CGFloat, at index: Int)
}

/// Positions every item from cached or estimated heights, pins the current turn's prompt, and keeps the reader's
/// place in the same layout pass in which anything above it changes size: a cell that self-sizes above the
/// anchor moves the content offset by the same amount through its invalidation context, and data updates
/// restore the anchor from `targetContentOffset`. Nothing corrects the offset afterwards.
final class TranscriptLayout: UICollectionViewLayout {
  private(set) var geometry = TranscriptGeometry()
  weak var delegate: TranscriptLayoutDelegate?
  /// Restored by the next data update instead of UIKit's proposed offset.
  var pendingAnchor: TranscriptGeometry.Anchor?
  private var pinnedIndex: Int?

  override class var layoutAttributesClass: AnyClass { TranscriptLayoutAttributes.self }
  override class var invalidationContextClass: AnyClass { UICollectionViewLayoutInvalidationContext.self }

  /// Where each item's message starts: the index of its first item and the padding above that item that
  /// belongs to the message (reading positions measure from the message's top, as the List rows did).
  struct Owner: Equatable {
    var start: Int
    var inset: CGFloat
  }
  private var owners: [Owner] = []
  /// Whether each height was measured, rather than estimated, for the current content and width.
  private var measured: [Bool] = []

  func replace(_ entries: [TranscriptGeometry.Entry], owners: [Owner], measured: [Bool]) {
    geometry.replace(entries)
    self.owners = owners
    self.measured = measured
  }
  func isMeasured(_ index: Int) -> Bool { measured.indices.contains(index) && measured[index] }
  /// Content position of the top of the message that owns the item.
  func messageTop(_ index: Int) -> CGFloat {
    let owner = owners.indices.contains(index) ? owners[index] : Owner(start: index, inset: 0)
    return CGFloat(geometry.tops[owner.start]) - owner.inset
  }
  func setHeight(_ height: CGFloat, at index: Int) { geometry.setHeight(Double(height), at: index) }
  func setSpacerPrompt(_ id: String?) { geometry.spacerPrompt = id }
  func setBottomPadding(_ padding: CGFloat) { geometry.bottomPadding = Double(padding) }

  var visibleTop: CGFloat { collectionView.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? 0 }
  var viewport: CGFloat {
    collectionView.map { $0.bounds.height - $0.adjustedContentInset.top - $0.adjustedContentInset.bottom } ?? 0
  }
  /// The reader's place. The history control at the very top is never it: older pages land below that
  /// control, so anchoring on it would push the passage down by a whole page.
  var anchor: TranscriptGeometry.Anchor? {
    guard let anchor = geometry.anchor(visibleTop: Double(visibleTop)) else { return nil }
    guard anchor.id == "older", geometry.count > 1 else { return anchor }
    return .init(id: geometry.entries[1].id, screenY: geometry.tops[1] - Double(visibleTop))
  }
  var usableTop: CGFloat { CGFloat(geometry.usableTop(visibleTop: Double(visibleTop))) }
  var pinned: TranscriptGeometry.Pinned? { geometry.pinned(visibleTop: Double(visibleTop)) }
  /// The largest offset, including the trailing space of a just-sent prompt.
  var maximumOffset: CGFloat {
    guard let collectionView else { return 0 }
    return max(-collectionView.adjustedContentInset.top,
      collectionViewContentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
  }
  func offset(for anchor: TranscriptGeometry.Anchor) -> CGFloat? {
    geometry.visibleTop(for: anchor).map { CGFloat($0) - (collectionView?.adjustedContentInset.top ?? 0) }
  }

  /// The bottom edge of what the reader last saw. Content that shrinks below it (an estimate measured smaller,
  /// a row replaced) keeps this much scrollable space, so the offset is never clamped and the screen never
  /// moves; the reader's next drag releases it.
  var contentFloor: CGFloat = 0
  /// Opened at the end, with nothing added since: the cells measured after the first frame (SwiftUI settles
  /// some a pass later) correct their estimates without new content, so the end stays at the end.
  var keepsEnd = false
  /// Items whose text got the beginning it was shown without: they grow above the reader's place.
  var growsAtStart: Set<String> = []

  override var collectionViewContentSize: CGSize {
    CGSize(width: collectionView?.bounds.width ?? 0,
      height: max(CGFloat(geometry.contentHeight(viewport: Double(viewport))), contentFloor))
  }

  override func prepare() {
    super.prepare()
    pinnedIndex = pinned?.index
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    guard geometry.count > 0 else { return [] }
    var result: [UICollectionViewLayoutAttributes] = []
    var index = geometry.firstIndex(below: Double(rect.minY))
    while index < geometry.count, geometry.tops[index] < Double(rect.maxY) {
      result.append(attributes(index))
      index += 1
    }
    if let pinned = pinned, !result.contains(where: { $0.indexPath.item == pinned.index }) {
      result.append(attributes(pinned.index))
    }
    return result
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard indexPath.item < geometry.count else { return nil }
    return attributes(indexPath.item)
  }

  private func attributes(_ index: Int) -> TranscriptLayoutAttributes {
    let attributes = TranscriptLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
    let entry = geometry.entries[index]
    var y = CGFloat(geometry.tops[index])
    if let pinned, pinned.index == index {
      y = CGFloat(pinned.y)
      // The fade shows once content passes under the prompt.
      attributes.pinned = y > CGFloat(geometry.tops[index]) + 0.5
      attributes.zIndex = 20
    } else {
      attributes.zIndex = entry.sticky ? 10 : 0
    }
    attributes.frame = CGRect(x: 0, y: y, width: collectionView?.bounds.width ?? 0, height: CGFloat(entry.height))
    attributes.messageOffset = CGFloat(geometry.tops[index]) - messageTop(index)
    return attributes
  }

  // MARK: Scrolling: only the pinned prompt moves.

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let collectionView else { return false }
    return newBounds.width != collectionView.bounds.width || newBounds.height != collectionView.bounds.height
      || geometry.pinned(visibleTop: Double(newBounds.minY + collectionView.adjustedContentInset.top))?.index
        != pinnedIndex || pinnedIndex != nil
  }

  override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
    let context = super.invalidationContext(forBoundsChange: newBounds)
    guard let collectionView, newBounds.width == collectionView.bounds.width else { return context }
    let next = geometry.pinned(visibleTop: Double(newBounds.minY + collectionView.adjustedContentInset.top))?.index
    let changed = Set([pinnedIndex, next].compactMap { $0 }).filter { $0 < geometry.count }
    if !changed.isEmpty { context.invalidateItems(at: changed.map { IndexPath(item: $0, section: 0) }) }
    return context
  }

  // MARK: Self-sizing, anchored in the same pass.

  override func shouldInvalidateLayout(
    forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
    withOriginalAttributes original: UICollectionViewLayoutAttributes
  ) -> Bool {
    let index = original.indexPath.item
    guard index < geometry.count else { return false }
    return abs(preferred.frame.height - CGFloat(geometry.entries[index].height)) > 0.25
  }

  override func invalidationContext(
    forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
    withOriginalAttributes original: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutInvalidationContext {
    let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
    let index = original.indexPath.item
    guard index < geometry.count else { return context }
    // Above the reader's place everything below shifts by the same amount: move the offset with it. A
    // measured place that changes (a streamed answer, an expansion) keeps its top; below it, nothing moves.
    // An unmeasured place showed nothing yet: entering above everything already on screen (under the pinned
    // prompt while scrolling up), it keeps what follows it still; below shown content, it keeps its top.
    let place = anchor.flatMap { geometry.index(of: $0.id) }
    var above = place.map { index < $0 } ?? false
    if let place, index == place, !isMeasured(index) {
      let displaced = pinned.flatMap { $0.y > geometry.tops[$0.index] + 0.5 ? $0.index : nil }
      let shown = (collectionView?.indexPathsForVisibleItems ?? []).map(\.item)
        .filter { $0 != index && $0 != displaced && isMeasured($0) }.min()
      above = shown.map { index < $0 } ?? true
    }
    if growsAtStart.remove(geometry.entries[index].id) != nil, index == place { above = true }
    if keepsEnd, !above, Double(visibleTop + viewport) >= geometry.contentEnd - 1,
      geometry.spacer(viewport: Double(viewport)) == 0
    {
      above = true
    }
    let delta = geometry.setHeight(Double(preferred.frame.height), at: index)
    if measured.indices.contains(index) { measured[index] = true }
    delegate?.layout(self, measured: preferred.frame.height, at: index)
    context.contentSizeAdjustment = CGSize(width: 0, height: CGFloat(delta))
    if above {
      context.contentOffsetAdjustment = CGPoint(x: 0, y: CGFloat(delta))
    }
    let visible = collectionView?.indexPathsForVisibleItems ?? []
    context.invalidateItems(at: Array(Set(visible + [original.indexPath]).filter { $0.item < geometry.count }))
    return context
  }

  // MARK: Data updates restore the anchor.

  override func targetContentOffset(forProposedContentOffset proposed: CGPoint) -> CGPoint {
    guard let anchor = pendingAnchor, let offset = offset(for: anchor) else { return proposed }
    return CGPoint(x: proposed.x, y: min(max(offset, -(collectionView?.adjustedContentInset.top ?? 0)), maximumOffset))
  }

  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    layoutAttributesForItem(at: itemIndexPath)
  }
  override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    nil
  }
}
