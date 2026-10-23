import SwiftUI

struct UserPrompt: UIViewRepresentable {
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
    value.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: value.length))
    if view.label.attributedText?.isEqual(to: value) != true {
      view.label.attributedText = value
      view.measurements.removeAll(keepingCapacity: true)
    }
    view.label.textColor = theme.uiColor(.userBubbleText)
    view.label.accessibilityLabel = String(text.characters)
    view.collapsed = collapsed
    view.truncationChanged = truncationChanged
    view.expand = expand
    view.revealRange = revealRange
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
  var measurements: [CGFloat: (full: CGSize, clamped: CGSize)] = [:]
  private var reported: Bool?
  private var truncated = false

  init() {
    super.init(frame: .zero)
    contentInsetAdjustmentBehavior = .never
    showsVerticalScrollIndicator = false
    bounces = false
    label.font = .systemFont(ofSize: 16)
    label.lineBreakMode = .byTruncatingTail
    label.attributedText = NSAttributedString(string: "")
    label.isUserInteractionEnabled = true
    label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
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
    guard !collapsed, isScrollEnabled, let revealRange,
      revealedRange != revealRange || revealedSize != bounds.size,
      bounds.height > 0, let text = label.attributedText else { return }
    let storage = NSTextStorage(attributedString: text)
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(forCharacterRange: revealRange, actualCharacterRange: nil)
    scrollRectToVisible(layout.boundingRect(forGlyphRange: glyphs, in: container), animated: false)
    revealedRange = revealRange
    revealedSize = bounds.size
  }

  @objc private func tapped() {
    if collapsed && truncated { expand?() }
  }
}
