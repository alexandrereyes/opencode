import AppKit
import OpenCodeKit
import SwiftUI

/// One materialized transcript item. Its frame comes from the geometry; it reports its height for a width.
class MacTranscriptCell: NSView {
  private(set) var item: TranscriptItem?
  /// False until measured again (a new width or theme): its height may differ.
  private(set) var valid = false
  private let fade = CAGradientLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    fade.startPoint = CGPoint(x: 0.5, y: 1)
    fade.endPoint = CGPoint(x: 0.5, y: 0)
    fade.isHidden = true
    layer?.addSublayer(fade)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }

  func configure(_ item: TranscriptItem, context: MacTranscriptContext) {
    self.item = item
    valid = false
    let color = context.theme.nsColor(.background).cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.colors = [color, context.theme.nsColor(.background).withAlphaComponent(0).cgColor]
    CATransaction.commit()
  }

  func measure(width: CGFloat, context: MacTranscriptContext) -> CGFloat {
    valid = true
    return 0
  }

  func invalidate() { valid = false }

  func quoteTop(_ id: String) -> CGFloat? {
    func find(_ view: NSView) -> CGFloat? {
      if let text = view as? MacResponseTextView, let top = text.quoteTop(id) {
        return text.convert(CGPoint(x: 0, y: top), to: self).y
      }
      return view.subviews.lazy.compactMap(find).first
    }
    return find(self)
  }

  /// A prompt pinned at the top with content passing under it draws a fade below itself.
  func setPinned(_ pinned: Bool) {
    guard fade.isHidden == pinned || fade.frame.width != bounds.width else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fade.isHidden = !pinned
    fade.frame = CGRect(x: 0, y: bounds.height, width: bounds.width, height: 14)
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    if !fade.isHidden {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fade.frame = CGRect(x: 0, y: bounds.height, width: bounds.width, height: 14)
      CATransaction.commit()
    }
  }
}

/// Prose of a response: one native text view, configured and measured synchronously. It starts after the icons'
/// gutter; the first item of an answer draws the OpenCode icon in it.
final class MacProseCell: MacTranscriptCell {
  let text = MacResponseTextView()
  private let icon = MacResponseIconView()
  private var inset: CGFloat = 24

  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(text)
    addSubview(icon)
  }
  required init?(coder: NSCoder) { nil }

  override func configure(_ item: TranscriptItem, context: MacTranscriptContext) {
    super.configure(item, context: context)
    guard case .prose(let part, let prose) = item.kind else { return }
    configure(part, prose: prose, context: context)
  }

  func configure(_ part: TranscriptPart, prose: MarkdownProse, context: MacTranscriptContext) {
    text.context = context
    text.part = part
    inset = context.inset
    let value = MacResponseTextStyle.text(prose, theme: context.theme, rasters: context.rasters(part))
    highlight(value, prose: prose, part: part, context: context)
    text.show(value, prose: prose, theme: context.theme)
    setAccessibilityIdentifier(item?.id)
    icon.isHidden = !(item.map { context.responseStarts.contains($0.id) } ?? false)
    placeText()
  }

  /// Search matches and quote marks, mapped from the part's source to the shown text.
  private func highlight(_ value: NSMutableAttributedString, prose: MarkdownProse, part: TranscriptPart,
    context: MacTranscriptContext)
  {
    let length = value.length
    func mark(_ range: NSRange, _ color: NSColor) {
      for shown in ConversationSearch.renderedRanges(range, block: prose.block) where NSMaxRange(shown) <= length {
        value.addAttribute(.backgroundColor, value: color, range: shown)
      }
    }
    for match in context.search.matches where match.partID == part.partID {
      let current = context.search.current == match.id
      mark(match.range, context.theme.nsColor(current ? .warning : .textAccent).withAlphaComponent(current ? 0.45 : 0.2))
    }
  }

  override func measure(width: CGFloat, context: MacTranscriptContext) -> CGFloat {
    _ = super.measure(width: width, context: context)
    inset = context.inset
    return text.fittingHeight(width: max(1, width - inset * 2 - MacTranscriptContext.gutter))
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    placeText()
  }

  private func placeText() {
    let gutter = MacTranscriptContext.gutter
    let frame = CGRect(x: inset + gutter, y: 0, width: max(1, bounds.width - inset * 2 - gutter), height: bounds.height)
    if text.frame != frame { text.frame = frame }
    let side = MacTranscriptContext.icon
    let place = CGRect(x: inset, y: 0, width: side, height: side)
    if icon.frame != place { icon.frame = place }
  }

  func reset() {
    text.setSelectedRange(NSRange(location: 0, length: 0))
  }
}

/// The OpenCode mascot (the app icon's artwork, still) in a circle at the top left of an answer.
/// The image is set in `updateLayer`: contents set once on an AppKit-backed layer were replaced by an empty draw on
/// the next display (a theme or scale change, a reused cell), leaving an empty circle.
final class MacResponseIconView: NSView {
  private static let mascot = NSImage(named: "OpenCodeMascot")
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    guard let layer else { return }
    layer.contents = Self.mascot?.layerContents(forContentsScale: window?.backingScaleFactor ?? 2)
    layer.contentsGravity = .resizeAspectFill
    layer.masksToBounds = true
    layer.cornerRadius = bounds.width / 2
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layer?.cornerRadius = newSize.width / 2
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Every other item: its SwiftUI view, hosted. It measures synchronously at a width, and tells the transcript
/// when its content changes size by itself (an expansion, an image that loaded, output that arrived).
final class MacHostCell: MacTranscriptCell {
  private let host = NSHostingController(rootView: MacTranscriptItemRoot(item: nil, context: nil, report: { _ in }))
  var resized: (String) -> Void = { _ in }
  private var reported: CGFloat = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    host.sizingOptions = []
    host.view.translatesAutoresizingMaskIntoConstraints = true
    host.view.autoresizingMask = [.width, .height]
    addSubview(host.view)
  }
  required init?(coder: NSCoder) { nil }

  override func configure(_ item: TranscriptItem, context: MacTranscriptContext) {
    super.configure(item, context: context)
    reported = 0
    let id = item.id
    host.rootView = MacTranscriptItemRoot(item: item, context: context) { [weak self] height in
      guard let self, self.item?.id == id, valid, abs(height - bounds.height) > 0.5, abs(height - reported) > 0.5
      else { return }
      reported = height
      resized(id)
    }
    setAccessibilityIdentifier(item.id)
  }

  override func measure(width: CGFloat, context: MacTranscriptContext) -> CGFloat {
    _ = super.measure(width: width, context: context)
    if case .unparsed = item?.kind { return bounds.height > 0 ? bounds.height : 20 }
    let size = host.sizeThatFits(in: CGSize(width: width, height: CGFloat.infinity))
    reported = ceil(size.height)
    return reported
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    if host.view.frame != bounds { host.view.frame = bounds }
  }
}

/// The hosted root: the item's view at the top of its cell, reporting its natural height.
struct MacTranscriptItemRoot: View {
  let item: TranscriptItem?
  let context: MacTranscriptContext?
  let report: (CGFloat) -> Void

  var body: some View {
    if let item, let context {
      MacTopAligned {
        MacTranscriptItemView(item: item, context: context)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
      }
      .environment(\.appTheme, context.theme)
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .environment(context.store.toast)
    }
  }
}

/// Lays its content out at its natural height for the width, at the top of the cell: measuring (an unbounded
/// height) gets that height, and a cell taller or shorter than it for a moment never centers it.
struct MacTopAligned: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? natural.height
    return CGSize(width: proposal.width ?? natural.width, height: height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: nil))
  }
}
