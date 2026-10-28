import OpenCodeKit
import SwiftUI

/// A transcript cell knows how far its item starts below its message's top, so offsets measured inside it
/// (search and quote alignment) can name a position in the message, as reading positions do.
protocol TranscriptMessageCell: UICollectionReusableView {
  var messageOffset: CGFloat { get }
}

extension UICollectionReusableView {
  /// Offset of a point in this cell from the top of its message (the cell itself outside the transcript).
  func messageY(_ y: CGFloat) -> CGFloat { y + ((self as? TranscriptMessageCell)?.messageOffset ?? 0) }
}

/// Prose of a response: one native text view, configured and measured synchronously.
final class TranscriptTextCell: UICollectionViewCell, TranscriptMessageCell {
  let text: ResponseTextView
  let coordinator = SelectableResponseText.Coordinator()
  private(set) var messageOffset: CGFloat = 0

  override init(frame: CGRect) {
    text = SelectableResponseText.makeTextView(coordinator: coordinator)
    super.init(frame: frame)
    contentView.addSubview(text)
  }
  required init?(coder: NSCoder) { nil }

  func configure(_ part: TranscriptPart, prose: MarkdownProse, context: TranscriptContext) {
    SelectableResponseText(
      block: prose.block, messageID: part.messageID, partID: part.partID, theme: context.theme, prose: prose,
      source: part.source, actions: context.selection, selectionChanged: context.selectionChanged?.selected,
      highlights: context.search, rasters: context.rasters(part), openNote: { context.openNote(part, $0) },
      fileContextOverride: context.images, fileOpenOverride: context.openFile?.open,
      folderOpenOverride: context.openFile?.folder, filesStableOverride: part.stable,
      contentSizeOverride: traitCollection.preferredContentSizeCategory, quotesOverride: context.responseQuotes(part)
    ).configure(text, coordinator: coordinator)
    setNeedsLayout()
  }

  func height(width: CGFloat) -> CGFloat {
    let width = max(1, width - AppLayout.margin * 2)
    // Its own container at this width lets the text view measure incrementally.
    if text.bounds.width != width { text.frame.size.width = width }
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMeasureCheck") {
      let laid = text.fittingSize(width: width).height
      let fitted = ceil(text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
      if abs(laid - fitted) > 0.5 { NSLog("TRANSCRIPT measure mismatch laid=%.1f fitted=%.1f", laid, fitted) }
    }
    #endif
    return ceil(text.fittingSize(width: width).height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    text.frame = contentView.bounds.insetBy(dx: AppLayout.margin, dy: 0)
  }

  override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
    super.apply(layoutAttributes)
    messageOffset = (layoutAttributes as? TranscriptLayoutAttributes)?.messageOffset ?? 0
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
    attributes.frame.size.height = height(width: layoutAttributes.frame.width)
    return attributes
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    text.clearSelection()
  }
}

/// Every other item: its existing SwiftUI view, hosted. Prompts draw a fade below themselves while pinned.
final class TranscriptHostCell: UICollectionViewCell, TranscriptMessageCell {
  private let fade = CAGradientLayer()
  private(set) var itemID = ""
  /// A placeholder keeps the estimated height it was laid out with: measuring its empty content would cache
  /// a height that no content has.
  private var placeholder = false
  private(set) var messageOffset: CGFloat = 0
  private var fadeColor: UIColor?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    fade.startPoint = CGPoint(x: 0.5, y: 0)
    fade.endPoint = CGPoint(x: 0.5, y: 1)
    fade.isHidden = true
    layer.addSublayer(fade)
  }
  required init?(coder: NSCoder) { nil }

  func configure(_ item: TranscriptItem, context: TranscriptContext) {
    itemID = item.id
    if case .unparsed = item.kind { placeholder = true } else { placeholder = false }
    contentConfiguration = UIHostingConfiguration { TranscriptItemView(item: item, context: context) }
      .margins(.all, 0)
    let color = context.theme.uiColor(.background)
    if fadeColor != color {
      fadeColor = color
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fade.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
      CATransaction.commit()
    }
  }

  override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
    super.apply(layoutAttributes)
    let attributes = layoutAttributes as? TranscriptLayoutAttributes
    messageOffset = attributes?.messageOffset ?? 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.isHidden = attributes?.pinned != true
    fade.frame = CGRect(x: 0, y: layoutAttributes.frame.height, width: layoutAttributes.frame.width, height: 14)
    CATransaction.commit()
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
    if placeholder { return attributes }
    let size = contentView.systemLayoutSizeFitting(
      CGSize(width: layoutAttributes.frame.width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    attributes.frame.size.height = ceil(size.height)
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeScrollDiagnostics") {
      NSLog("TRANSCRIPT fit %@ %@ at %d: %.1f (was %.1f)", String(describing: ObjectIdentifier(self)), itemID,
        layoutAttributes.indexPath.item, attributes.frame.height, layoutAttributes.frame.height)
    }
    #endif
    return attributes
  }
}
