import SwiftUI

struct UserPrompt: UIViewRepresentable {
  @Environment(\.dynamicTypeSize) private var typeSize
  let text: AttributedString
  let theme: AppTheme
  let collapsed: Bool
  let maximumHeight: CGFloat
  let revealRange: NSRange?
  let truncationChanged: (Bool) -> Void
  let expand: () -> Void

  func makeUIView(context: Context) -> UserPromptScrollView { UserPromptScrollView() }
  func updateUIView(_ view: UserPromptScrollView, context: Context) {
    let value = NSMutableAttributedString(attributedString: NSAttributedString(text))
    let traits = UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory)
    let font = AppTypography.font(.message, compatibleWith: traits)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = AppTypography.lineHeight(.message, compatibleWith: traits)
    paragraph.lineBreakMode = .byTruncatingTail
    value.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: value.length))
    if view.label.font != font || view.label.attributedText?.isEqual(to: value) != true {
      view.label.font = font
      view.label.attributedText = value
      view.measurements.removeAll(keepingCapacity: true)
    }
    view.label.textColor = theme.uiColor(.userBubbleText)
    view.label.accessibilityLabel = String(text.characters)
    view.collapsed = collapsed
    view.truncationChanged = truncationChanged
    view.expand = expand
    view.revealRange = revealRange
    view.setNeedsLayout()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UserPromptScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return uiView.measure(width: width, maximumHeight: maximumHeight)
  }
}

final class UserPromptScrollView: UIScrollView {
  let label = UILabel()
  var collapsed = true
  var truncationChanged: ((Bool) -> Void)?
  var expand: (() -> Void)?
  var revealRange: NSRange? {
    didSet { if revealRange != oldValue { revealedRange = nil } }
  }
  private var revealedRange: NSRange?
  private var revealedSize: CGSize?
  private var revealedContainerSize: CGSize?
  var measurements: [CGFloat: (full: CGSize, clamped: CGSize)] = [:]
  private var reported: Bool?
  private var truncated = false

  init() {
    super.init(frame: .zero)
    contentInsetAdjustmentBehavior = .never
    showsVerticalScrollIndicator = false
    bounces = false
    label.font = AppTypography.font(.message)
    label.lineBreakMode = .byTruncatingTail
    label.attributedText = NSAttributedString(string: "")
    label.isUserInteractionEnabled = true
    label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    // UIKit infers a button from the tap gesture; reading the prompt must remain
    // separate from the explicit expansion control below it.
    label.isAccessibilityElement = true
    label.accessibilityTraits = .staticText
    addSubview(label)
  }
  required init?(coder: NSCoder) { nil }

  func measure(width: CGFloat, maximumHeight: CGFloat) -> CGSize {
    let measured: (full: CGSize, clamped: CGSize)
    if let cached = measurements[width] {
      measured = cached
    } else {
      label.numberOfLines = 0
      let full = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      label.numberOfLines = 2
      measured = (full, label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
      if measurements.count >= 8 { measurements.removeAll(keepingCapacity: true) }
      measurements[width] = measured
    }
    truncated = measured.full.height > measured.clamped.height
    label.numberOfLines = collapsed ? 2 : 0
    let size = collapsed ? measured.clamped : measured.full
    let visible = CGSize(width: truncated ? width : min(width, size.width), height: min(size.height, maximumHeight))
    label.frame = CGRect(origin: .zero, size: CGSize(width: visible.width, height: size.height))
    contentSize = label.bounds.size
    isScrollEnabled = size.height > maximumHeight
    if !isScrollEnabled { contentOffset = .zero }
    if reported != truncated {
      reported = truncated
      // SwiftUI must finish its current measurement before publishing the affordance.
      Task { @MainActor [weak self] in
        guard let self else { return }
        truncationChanged?(truncated)
      }
    }
    return visible
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let viewport = sequence(first: superview, next: { $0?.superview })
      .compactMap { $0 as? UIScrollView }.first
    guard !collapsed, let revealRange,
      revealedRange != revealRange || revealedSize != bounds.size || revealedContainerSize != viewport?.bounds.size,
      bounds.height > 0, let text = label.attributedText else { return }
    let storage = NSTextStorage(attributedString: text)
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(forCharacterRange: revealRange, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    scrollRectToVisible(rect, animated: false)
    // Reveal through the message's context viewport, never through the transcript's
    // collection view, whose reading/follow corrections have a separate owner.
    if let viewport, !(viewport is UICollectionView) {
      viewport.scrollRectToVisible(label.convert(rect, to: viewport), animated: false)
    }
    revealedRange = revealRange
    revealedSize = bounds.size
    revealedContainerSize = viewport?.bounds.size
  }

  @objc private func tapped() {
    if collapsed && truncated { expand?() }
  }
}
