import OpenCodeKit
import UIKit

struct ResponseQuoteInsertion {
  let mark: ChatQuoteMark
  let offset: Int
  let range: NSRange
}

extension ResponseTextView {
  func configureQuotes(_ context: ResponseQuoteContext, block: MarkdownBlock, theme: AppTheme) {
    let highlights = context.highlights.compactMap { highlight -> ResponseQuoteHighlight? in
      let ranges = highlight.ranges.flatMap { ConversationSearch.renderedRanges($0, block: block) }
      let ending = highlight.ranges.last.map {
        !ConversationSearch.renderedRanges(NSRange(location: NSMaxRange($0) - 1, length: 1), block: block).isEmpty
      } ?? false
      return ranges.isEmpty ? nil : ResponseQuoteHighlight(mark: highlight.mark, ranges: ranges, badge: highlight.badge && ending)
    }
    guard !highlights.isEmpty || !quoteHighlights.isEmpty else { return }
    openQuote = context.open
    quoteTarget = context.target
    quoteActive = context.active
    quoteAlign = context.align
    quoteFill = theme.uiColor(.quoteHighlight).withAlphaComponent(0.12)
    quoteLine = theme.uiColor(.quoteUnderline).withAlphaComponent(0.4)
    quoteBadge = theme.uiColor(.quoteBadge)
    if quoteHighlights != highlights {
      quoteHighlights = highlights
      quoteGeometryDirty = true
    }
    setNeedsLayout()
    setNeedsDisplay()
  }

  func renderQuoteMarkers(in text: NSMutableAttributedString, traits: UITraitCollection) {
    let markers = quoteHighlights.filter(\.badge).compactMap { highlight -> (ChatQuoteMark, Int)? in
      highlight.ranges.last.map { (highlight.mark, NSMaxRange($0)) }
    }.sorted { $0.1 == $1.1 ? $0.0.number < $1.0.number : $0.1 < $1.1 }
    quoteInsertions = markers.enumerated().map { index, entry in
      let previous = markers.prefix(index).reduce(0) { $0 + String($1.0.number).utf16.count }
      return ResponseQuoteInsertion(mark: entry.0, offset: entry.1,
        range: NSRange(location: entry.1 + previous, length: String(entry.0.number).utf16.count))
    }
    for insertion in quoteInsertions {
      text.insert(NSAttributedString(string: String(insertion.mark.number), attributes: [
        .font: AppTypography.font(.chrome, compatibleWith: traits), .baselineOffset: 6,
        .foregroundColor: quoteBadge,
      ]), at: insertion.range.location)
    }
  }

  // Marker characters participate in native line breaking, never in authored/source offsets.
  func originalRange(_ range: NSRange) -> NSRange {
    func offset(_ value: Int) -> Int {
      value - quoteInsertions.reduce(0) { $0 + min($1.range.length, max(0, value - $1.range.location)) }
    }
    return NSRange(location: offset(range.location), length: offset(NSMaxRange(range)) - offset(range.location))
  }
  func displayRange(_ range: NSRange) -> NSRange {
    let start = range.location + quoteInsertions.filter { $0.offset <= range.location }.reduce(0) { $0 + $1.range.length }
    let end = NSMaxRange(range) + quoteInsertions.filter { $0.offset < NSMaxRange(range) }.reduce(0) { $0 + $1.range.length }
    return NSRange(location: start, length: max(0, end - start))
  }
  func displayRanges(_ range: NSRange) -> [NSRange] {
    let offsets = [range.location] + quoteInsertions.map(\.offset).filter { $0 > range.location && $0 < NSMaxRange(range) } + [NSMaxRange(range)]
    return zip(offsets, offsets.dropFirst()).compactMap { start, end in
      guard end > start else { return nil }
      return displayRange(NSRange(location: start, length: end - start))
    }
  }

  func layoutQuoteDecorations() {
    guard !quoteHighlights.isEmpty else {
      quoteButtons.forEach { $0.removeFromSuperview() }
      quoteButtons = []
      quoteRects = []
      return
    }
    if quoteGeometryDirty {
      // Marks often arrive after the text: an edit may not be laid out yet, and rects measured now would be
      // empty. Lay it out first; should it still yield nothing, measure again on the next pass.
      if let manager = textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
      quoteRects = quoteHighlights.map { highlight in
        (highlight.mark, highlight.ranges.flatMap(displayRanges).flatMap(textRects))
      }
      quoteGeometryDirty = quoteRects.contains { $0.1.isEmpty }
      quoteButtons.forEach { $0.removeFromSuperview() }
      quoteButtons = quoteInsertions.compactMap { insertion in
        guard let rect = textRects(insertion.range).first else { return nil }
        let button = UIButton(type: .custom)
        // The transparent target is larger than the superscript and adds no layout width/height.
        button.frame = CGRect(x: rect.midX - 22, y: rect.midY - 22, width: 44, height: 44)
        button.accessibilityLabel = "Citação \(insertion.mark.number)"
        button.accessibilityValue = insertion.mark.pending ? "rascunho" : "enviada"
        button.accessibilityIdentifier = "quote-marker-" + insertion.mark.id
        button.addAction(UIAction { [weak self] _ in
          guard let self, selectedRange.length == 0 else { return }
          selectionChanged?()
          openQuote?(insertion.mark)
        }, for: .touchUpInside)
        addSubview(button)
        return button
      }
      setNeedsDisplay()
    }
    guard let target = quoteTarget, let entry = quoteRects.first(where: { $0.0.id == target }),
      let rect = entry.1.first else { return }
    var parent = superview
    while let view = parent {
      if let view = view as? UICollectionReusableView {
        let offset = Double(view.messageY(convert(rect, to: view).minY))
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
  /// The text's rects from its own layout, whatever part of it the view has drawn so far: selection rects only
  /// cover what the view's viewport has laid out, which misses marks configured before the cell is sized.
  func textRects(_ range: NSRange) -> [CGRect] {
    guard let manager = textLayoutManager, let content = manager.textContentManager,
      let start = content.location(content.documentRange.location, offsetBy: range.location),
      let end = content.location(start, offsetBy: range.length), let text = NSTextRange(location: start, end: end)
    else { return [] }
    manager.ensureLayout(for: text)
    var rects: [CGRect] = []
    manager.enumerateTextSegments(in: text, type: .standard, options: []) { _, frame, _, _ in
      if frame.width > 0, frame.height > 0 {
        rects.append(frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top))
      }
      return true
    }
    return rects
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
