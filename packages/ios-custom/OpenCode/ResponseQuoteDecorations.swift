import OpenCodeKit
import UIKit

extension ResponseTextView {
  func configureQuotes(_ context: ResponseQuoteContext, block: MarkdownBlock, theme: AppTheme) {
    let highlights = context.highlights.compactMap { highlight -> ResponseQuoteHighlight? in
      let ranges = highlight.ranges.flatMap { ConversationSearch.renderedRanges($0, block: block) }
      let ending = highlight.ranges.last.map {
        !ConversationSearch.renderedRanges(NSRange(location: NSMaxRange($0) - 1, length: 1), block: block).isEmpty
      } ?? false
      return ranges.isEmpty ? nil : ResponseQuoteHighlight(mark: highlight.mark, ranges: ranges, badge: ending)
    }
    guard !highlights.isEmpty || !quoteHighlights.isEmpty else { return }
    openQuote = context.open
    quoteTarget = context.target
    quoteActive = context.active
    quoteAlign = context.align
    quoteFill = theme.uiColor(.quoteHighlight).withAlphaComponent(0.12)
    quoteLine = theme.uiColor(.quoteUnderline).withAlphaComponent(0.4)
    quoteBadge = theme.uiColor(.quoteBadge)
    quoteText = theme.uiColor(.text)
    quoteSurface = theme.uiColor(.quoteBadgeSurface)
    if quoteHighlights != highlights {
      let gutterChanged = quoteHighlights.isEmpty != highlights.isEmpty
      quoteHighlights = highlights
      quoteGeometryDirty = true
      if gutterChanged {
        textContainerInset.right = highlights.isEmpty ? 0 : 28
        invalidateMeasurement()
      }
    }
    quoteButtons.forEach {
      $0.setTitleColor(theme.uiColor(.text), for: .normal)
      $0.layer.borderColor = quoteBadge.cgColor
      $0.backgroundColor = quoteSurface
    }
    setNeedsLayout()
    setNeedsDisplay()
  }
  func layoutQuoteDecorations() {
    guard !quoteHighlights.isEmpty else {
      quoteRail?.isHidden = true
      quoteRects = []
      return
    }
    let rail = quoteRail ?? UIScrollView()
    if quoteRail == nil {
      rail.showsVerticalScrollIndicator = false
      rail.bounces = false
      rail.backgroundColor = .clear
      addSubview(rail)
      quoteRail = rail
    }
    rail.frame = CGRect(x: bounds.width - 28, y: 0, width: 28, height: bounds.height)
    if quoteGeometryDirty {
      quoteGeometryDirty = false
      quoteRects = quoteHighlights.map { highlight in
        (highlight.mark, highlight.ranges.flatMap { range -> [CGRect] in
          guard let start = position(from: beginningOfDocument, offset: range.location),
            let end = position(from: start, offset: range.length), let text = textRange(from: start, to: end) else { return [] }
          return selectionRects(for: text).map(\.rect).filter { $0.width > 0 && $0.height > 0 }
        })
      }
      quoteButtons.forEach { $0.removeFromSuperview() }
      quoteButtons = []
      var bottom: CGFloat = 0
      for (index, entry) in quoteRects.enumerated() {
        let (mark, rects) = entry
        guard quoteHighlights[index].badge else { continue }
        guard let rect = rects.last else { continue }
        let button = UIButton(type: .custom)
        button.setTitle(String(mark.number), for: .normal)
        button.titleLabel?.font = AppTypography.font(.caption)
        button.setTitleColor(quoteText, for: .normal)
        button.backgroundColor = quoteSurface
        button.layer.borderColor = quoteBadge.cgColor
        button.layer.borderWidth = 1
        button.layer.cornerRadius = 12
        let y = max(bottom, rect.midY - 12)
        button.frame = CGRect(x: 4, y: y, width: 24, height: 24)
        bottom = y + 28
        button.accessibilityLabel = "Citação \(mark.number)" + (mark.pending ? ", rascunho" : ", enviada")
        button.accessibilityIdentifier = "quote-marker-" + mark.id
        button.addAction(UIAction { [weak self] _ in
          self?.selectionChanged?()
          self?.openQuote?(mark)
        }, for: .touchUpInside)
        rail.addSubview(button)
        quoteButtons.append(button)
      }
      rail.contentSize = CGSize(width: 28, height: max(bounds.height, bottom))
      rail.isHidden = quoteButtons.isEmpty
      setNeedsDisplay()
    }
    guard let target = quoteTarget, let entry = quoteRects.first(where: { $0.0.id == target }),
      let rect = entry.1.first else { return }
    var parent = superview
    while let view = parent {
      if view is UICollectionReusableView {
        let offset = Double(convert(rect, to: view).minY)
        guard offset.isFinite else { return }
        Task { @MainActor [weak self] in
          guard let self, quoteTarget == target else { return }
          quoteAlign?(target, messageID, offset)
        }
        return
      }
      parent = view.superview
    }
  }
  func drawQuoteDecorations() {
    for (mark, rects) in quoteRects {
      for rect in rects {
        (quoteActive == mark.id ? quoteFill.withAlphaComponent(0.28) : quoteFill).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 2).fill()
        quoteLine.setFill()
        UIBezierPath(rect: CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1)).fill()
      }
    }
  }
  func quote(at point: CGPoint) -> ChatQuoteMark? {
    guard selectedRange.length == 0 else { return nil }
    if let position = closestPosition(to: point), let text = attributedText {
      let offset = offset(from: beginningOfDocument, to: position)
      if offset < text.length, text.attribute(.link, at: offset, effectiveRange: nil) != nil { return nil }
    }
    return quoteRects.first { $0.1.contains { $0.contains(point) } }?.0
  }
}
