import OpenCodeKit
import SwiftUI

struct ResponseSelectionActions {
  let comment: (ChatQuote) -> Void
  let sideQuestion: (String) -> Void
}
struct ResponseSelectionObserver {
  let selected: () -> Void
}
/// Both handlers read the conversation's current state when invoked, so any two copies are interchangeable.
extension ResponseSelectionActions: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
}
extension ResponseSelectionObserver: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { true }
}
extension EnvironmentValues {
  @Entry var responseSelection: ResponseSelectionActions? = nil
  @Entry var responseSelectionChanged: ResponseSelectionObserver? = nil
}

final class ResponseTextView: UITextView {
  private(set) var measuredSizes: [CGFloat: CGSize] = [:]
  override var attributedText: NSAttributedString! {
    didSet {
      invalidateMeasurement()
      lineBreaks.widths = [:]
      #if DEBUG
      if (oldValue?.length ?? 0) > 0, attributedText != nil { TranscriptCounters.replaced.add(1, ordering: .relaxed) }
      #endif
    }
  }
  private let lineBreaks = InlineCodeLineBreaks()
  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    lineBreaks.install(self)
    #if DEBUG
    TranscriptCounters.created.add(1, ordering: .relaxed)
    #endif
  }
  required init?(coder: NSCoder) { nil }
  #if DEBUG
  deinit { TranscriptCounters.destroyed.add(1, ordering: .relaxed) }
  #endif
  var codeGutter = false
  var gutterWidth: CGFloat = 44
  var inlineCodeRanges: [NSRange] = [] {
    didSet {
      guard inlineCodeRanges != oldValue, let manager = textLayoutManager else { return }
      lineBreaks.widths = [:]
      manager.invalidateLayout(for: manager.documentRange)
      invalidateMeasurement()
    }
  }
  var inlineCodeColor = UIColor.clear
  var gutterColor = UIColor.clear
  var gutterBorderColor = UIColor.clear
  var openNote: ((String) -> Void)?
  var openFile: ((String) -> Void)?
  var openFolder: ((String) -> Void)?
  var quoteHighlights: [ResponseQuoteHighlight] = []
  var quoteRects: [(ChatQuoteMark, [CGRect])] = []
  var quoteButtons: [UIButton] = []
  var quoteInsertions: [ResponseQuoteInsertion] = []
  var quoteFill = UIColor.clear
  var quoteLine = UIColor.clear
  var quoteBadge = UIColor.clear
  var openQuote: ((ChatQuoteMark) -> Void)?
  var quoteTarget: String?
  var quoteActive: String?
  var quoteAlign: ((String, String, Double) -> Void)?
  var quoteGeometryDirty = false
  /// Prose segments joined into this text; quotation borders and rules are drawn per segment.
  var prose: MarkdownProse?
  var quoteBorderColor = UIColor.clear
  var ruleColor = UIColor.clear
  private var decorationWidth: CGFloat?
  /// Display location from which decorations must be measured again; text before it kept its layout.
  private var decorationsFrom: Int? = 0
  private var inlineCode: [(range: NSRange, rects: [CGRect])] = []
  private var inlineCodeRects: [CGRect] { inlineCode.flatMap(\.rects) }
  private var lineRects: [CGRect] = []
  private var borderRects: [CGRect] = []
  private var ruleRects: [CGRect] = []
  func invalidateMeasurement() {
    measuredSizes.removeAll(keepingCapacity: true)
    decorationsFrom = 0
    setNeedsLayout()
  }
  /// Shows `text`, editing the existing storage from the first changed paragraph on when everything before
  /// it is identical, so a streamed answer's earlier paragraphs keep their layout and the view is not replaced.
  @discardableResult func show(_ text: NSAttributedString) -> Bool {
    let storage = textStorage
    guard storage.length > 0, text.length > 0 else {
      attributedText = text
      return false
    }
    let old = Array(storage.string.utf16)
    let new = Array(text.string.utf16)
    var common = 0
    let limit = min(old.count, new.count)
    while common < limit, old[common] == new[common] { common += 1 }
    // Restyling reaches back to the paragraph start (a closing `**` bolds text typed earlier).
    let start = common == 0 ? 0
      : (storage.string as NSString).paragraphRange(for: NSRange(location: min(common, old.count - 1), length: 0)).location
    guard start > 0,
      storage.attributedSubstring(from: NSRange(location: 0, length: start))
        .isEqual(to: text.attributedSubstring(from: NSRange(location: 0, length: start)))
    else {
      attributedText = text
      return false
    }
    storage.beginEditing()
    storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start),
      with: text.attributedSubstring(from: NSRange(location: start, length: text.length - start)))
    storage.endEditing()
    lineBreaks.widths = [:]
    measuredSizes.removeAll(keepingCapacity: true)
    decorationsFrom = min(decorationsFrom ?? start, start)
    setNeedsLayout()
    #if DEBUG
    TranscriptCounters.appended.add(1, ordering: .relaxed)
    #endif
    return true
  }
  func fittingSize(width: CGFloat) -> CGSize {
    if let size = measuredSizes[width] { return size }
    let size = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    if measuredSizes.count >= 8 { measuredSizes.removeAll(keepingCapacity: true) }
    measuredSizes[width] = size
    return size
  }
  override func copy(_ sender: Any?) {
    // Formulas, generated separators and quote markers copy their source text, not their glyphs.
    if let block = sourceBlock,
      !quoteInsertions.isEmpty || block.runs.contains(where: { $0.formula != nil || $0.copy != nil }) {
      UIPasteboard.general.string = block.copyText(in: originalRange(selectedRange))
    } else { super.copy(sender) }
    Haptics.play(.selection)
  }
  var messageID = ""
  var partID = ""
  var sourceBlock: MarkdownBlock?
  var source = ""
  var selectionActions: ResponseSelectionActions?
  var selectionChanged: (() -> Void)?
  var searchMatch: ConversationMatch?
  var searchRange: NSRange?
  var searchAlign: ((ConversationMatch, Double) -> Void)?
  override func layoutSubviews() {
    super.layoutSubviews()
    if decorationWidth != bounds.width {
      decorationWidth = bounds.width
      decorationsFrom = 0
    }
    if let from = decorationsFrom {
      decorationsFrom = nil
      quoteGeometryDirty = true
      // Text before `from` kept its layout: so did its inline code backgrounds.
      let kept = Dictionary(inlineCode.filter { NSMaxRange($0.range) <= from }.map { ($0.range, $0.rects) },
        uniquingKeysWith: { first, _ in first })
      inlineCode = inlineCodeRanges.map { range in
        if let rects = kept[range] { return (range, rects) }
        guard let start = position(from: beginningOfDocument, offset: range.location),
          let end = position(from: start, offset: range.length), let text = textRange(from: start, to: end)
        else { return (range, []) }
        return (range, selectionRects(for: text).map(\.rect).filter { $0.width > 0 })
      }
      layoutProseDecorations(from: from)
      lineRects = []
      if codeGutter {
        let units = Array((attributedText?.string ?? "").utf16)
        let starts = [0] + units.enumerated().compactMap { $0.element == 10 && $0.offset + 1 < units.count ? $0.offset + 1 : nil }
        lineRects = starts.compactMap { offset in
          position(from: beginningOfDocument, offset: offset).map { caretRect(for: $0) }
        }
      }
      // Decorations above the edited text are unchanged: redraw from it down only.
      if from > 0, let position = position(from: beginningOfDocument, offset: from) {
        let top = max(0, caretRect(for: position).minY - 8)
        setNeedsDisplay(CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top)))
      } else {
        setNeedsDisplay()
      }
    }
    layoutQuoteDecorations()
    guard let match = searchMatch, let range = searchRange, let align = searchAlign,
      let start = position(from: beginningOfDocument, offset: range.location),
      let end = position(from: start, offset: range.length),
      let textRange = textRange(from: start, to: end) else { return }
    var parent = superview
    while let view = parent {
      if let view = view as? UICollectionReusableView {
        let offset = view.messageY(convert(firstRect(for: textRange), to: view).minY)
        guard offset.isFinite else { return }
        Task { @MainActor [weak self] in
          guard self?.searchMatch?.id == match.id else { return }
          align(match, Double(offset))
        }
        return
      }
      parent = view.superview
    }
  }
  override func draw(_ rect: CGRect) {
    inlineCodeColor.setFill()
    inlineCodeRects.forEach { UIBezierPath(roundedRect: $0.insetBy(dx: -2.4, dy: -1.6), cornerRadius: 6).fill() }
    quoteBorderColor.setFill()
    borderRects.forEach { UIBezierPath(rect: $0).fill() }
    ruleColor.setFill()
    ruleRects.forEach { UIBezierPath(rect: $0).fill() }
    drawQuoteDecorations()
    super.draw(rect)
    guard codeGutter else { return }
    gutterBorderColor.setFill()
    UIBezierPath(rect: CGRect(x: gutterWidth * 31 / 44, y: 0, width: 1 / traitCollection.displayScale, height: bounds.height)).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: AppTypography.font(.secondary, monospaced: true, compatibleWith: traitCollection),
      .foregroundColor: gutterColor, .paragraphStyle: paragraph,
    ]
    for (index, line) in lineRects.enumerated() {
      (String(index + 1) as NSString).draw(in: CGRect(x: 0, y: line.minY, width: gutterWidth * 25 / 44, height: line.height + 2), withAttributes: attributes)
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    super.point(inside: point, with: event) || quoteButtons.contains { $0.frame.contains(point) }
  }
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
    if selectedRange.length == 0, let button = quoteButtons.filter({ $0.frame.contains(point) }).min(by: {
      pow($0.frame.midX - point.x, 2) + pow($0.frame.midY - point.y, 2)
        < pow($1.frame.midX - point.x, 2) + pow($1.frame.midY - point.y, 2)
    }) { return button }
    return super.hitTest(point, with: event)
  }
  var selectionSourceRange: NSRange? { sourceBlock?.sourceRange(for: originalRange(selectedRange)) }
  /// The laid-out rect of one prose segment, for alignment and fixtures.
  func segmentRect(_ index: Int) -> CGRect? {
    guard let prose, prose.ranges.indices.contains(index) else { return nil }
    let rects = displayRanges(prose.ranges[index]).flatMap(textRects)
    guard let first = rects.first else { return nil }
    return rects.dropFirst().reduce(first) { $0.union($1) }
  }
  private var segmentDecorations: [Int: (borders: [CGRect], rule: CGRect?)] = [:]
  private func layoutProseDecorations(from: Int) {
    guard let prose else {
      borderRects = []
      ruleRects = []
      segmentDecorations = [:]
      return
    }
    // Segments that end before the edit keep their rects.
    segmentDecorations = segmentDecorations.filter { index, _ in
      prose.ranges.indices.contains(index) && from > 0 && NSMaxRange(prose.ranges[index]) <= from
    }
    for (index, segment) in prose.segments.enumerated() where segmentDecorations[index] == nil {
      guard segment.quoteDepth > 0 || segment.kind == .rule, let rect = segmentRect(index) else { continue }
      if segment.kind == .rule {
        segmentDecorations[index] = ([], CGRect(x: segment.indent, y: rect.midY - 0.5,
          width: bounds.width - segment.indent, height: 1))
        continue
      }
      segmentDecorations[index] = ((0..<segment.quoteDepth).map {
        CGRect(x: segment.indent + CGFloat($0) * ResponseTextStyle.quoteLevel, y: rect.minY, width: 2, height: rect.height)
      }, nil)
    }
    let ordered = segmentDecorations.sorted { $0.key < $1.key }.map(\.value)
    borderRects = ordered.flatMap(\.borders)
    ruleRects = ordered.compactMap(\.rule)
  }
  func clearSelection() {
    selectedRange = NSRange(location: 0, length: 0)
    resignFirstResponder()
  }
}

/// Keeps short inline code of prose on one line: TextKit may not break inside it, so `/proventos` or `--all-pages`
/// moves to the next line instead of leaving `/` or `--` behind. Longer spans and table cells wrap as before.
/// Other delegate calls reach UIKit's own delegate, if any.
private final class InlineCodeLineBreaks: NSObject, NSTextLayoutManagerDelegate {
  weak var view: ResponseTextView?
  weak var original: NSTextLayoutManagerDelegate?
  var widths: [NSRange: CGFloat] = [:]

  func install(_ view: ResponseTextView) {
    self.view = view
    original = view.textLayoutManager?.delegate
    view.textLayoutManager?.delegate = self
  }

  func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineBefore location: any NSTextLocation,
    hyphenating: Bool) -> Bool {
    let allowed = original?.textLayoutManager?(textLayoutManager, shouldBreakLineBefore: location, hyphenating: hyphenating) ?? true
    guard allowed, let view, !view.inlineCodeRanges.isEmpty, view.sourceBlock?.kind != .table, let text = view.attributedText,
      let line = textLayoutManager.textContainer?.size.width, line > 0, line < 10_000 else { return allowed }
    let offset = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location)
    guard let range = view.inlineCodeRanges.first(where: { $0.location < offset && offset < NSMaxRange($0) }),
      NSMaxRange(range) <= text.length else { return true }
    let width = widths[range] ?? {
      let value = text.attributedSubstring(from: range).boundingRect(
        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width
      widths[range] = value
      return value
    }()
    let indent = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
    // Line breaking cannot split the space before `/` or `-`, so the preceding word moves along with the span;
    // spans up to half a line leave room for it, and wider ones keep wrapping normally.
    return width > (line - indent) / 2
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

struct SelectableResponseText: UIViewRepresentable {
  @Environment(\.responseQuotes) private var quotes
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.conversationImages) private var imageContext
  @Environment(\.openFile) private var fileAction
  @Environment(\.responseFilesStable) private var filesStable
  let block: MarkdownBlock
  let messageID: String
  let partID: String
  let theme: AppTheme
  /// Set for joined prose; `block` is then `prose.block`.
  var prose: MarkdownProse? = nil
  var source = ""
  var actions: ResponseSelectionActions? = nil
  var selectionChanged: (() -> Void)? = nil
  var highlights = ConversationSearchHighlight()
  var rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]
  var gutter = false
  var wrap = true
  var tableHeader = false
  var openNote: ((String) -> Void)? = nil
  var fileContextOverride: ConversationImageContext? = nil
  var fileOpenOverride: ((String) -> Void)? = nil
  var folderOpenOverride: ((String) -> Void)? = nil
  var filesStableOverride: Bool? = nil
  var contentSizeOverride: UIContentSizeCategory? = nil
  var quotesOverride: ResponseQuoteContext? = nil

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> ResponseTextContainer {
    ResponseTextContainer(makeView(coordinator: context.coordinator))
  }
  func makeView(coordinator: Coordinator) -> ResponseTextView { Self.makeTextView(coordinator: coordinator) }
  static func makeTextView(coordinator: Coordinator) -> ResponseTextView {
    // The ObjC textViewUsingTextLayoutManager factory bypasses Swift subclass defaults.
    // The designated initializer uses TextKit 2 by default on our deployment target.
    let view = ResponseTextView(frame: .zero, textContainer: nil)
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = false
    view.delegate = coordinator
    let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.openQuote(_:)))
    tap.delegate = coordinator
    view.addGestureRecognizer(tap)
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ container: ResponseTextContainer, context: Context) {
    configure(container.text, coordinator: context.coordinator)
  }
  func configure(_ view: ResponseTextView, coordinator: Coordinator) {
    let category = contentSizeOverride ?? typeSize.uiCategory
    if view.messageID != messageID || view.partID != partID || view.sourceBlock != block {
      view.clearSelection()
    }
    view.messageID = messageID
    view.accessibilityIdentifier = "response-\(messageID)-\(partID)"
    view.partID = partID
    view.sourceBlock = block
    view.prose = prose
    view.source = source
    view.selectionActions = actions
    view.selectionChanged = selectionChanged
    view.openNote = openNote
    view.openFile = fileOpenOverride ?? fileAction?.open
    view.openFolder = folderOpenOverride ?? fileAction?.folder
    view.configureQuotes(quotesOverride ?? quotes, block: block, theme: theme)
    if filesStableOverride ?? filesStable {
      coordinator.resolveFiles(view, block: block, context: fileContextOverride ?? imageContext)
    } else {
      coordinator.fileTask?.cancel()
      coordinator.fileKey = nil
      coordinator.knownFiles = [:]
    }
    view.tintColor = theme.uiColor(.markdownLink)
    view.searchMatch = highlights.matches.first { $0.partID == partID && $0.id == highlights.current }
    view.searchRange = view.searchMatch.flatMap { ConversationSearch.renderedRanges($0.range, block: block).first.map(view.displayRange) }
    view.searchAlign = highlights.align
    let matches = highlights.matches.filter { $0.partID == partID }
    let rendering = Rendering(
      block: block, prose: prose, theme: theme.id, matches: matches,
      current: matches.contains { $0.id == highlights.current } ? highlights.current : nil,
      gutter: gutter, wrap: wrap, tableHeader: tableHeader,
      contentSize: category.rawValue,
      quotes: view.quoteHighlights,
      formulas: block.runs.compactMap(\.formula).filter { rasters[ResponseFormulaKey($0)] != nil }.count)
    guard coordinator.rendering != rendering else { return }
    coordinator.rendering = rendering
    view.codeGutter = gutter
    view.gutterWidth = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 44,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    view.textContainerInset = UIEdgeInsets(top: 0, left: gutter ? view.gutterWidth : 0, bottom: 0, right: 0)
    view.textContainer.lineBreakMode = wrap ? .byWordWrapping : .byClipping
    view.inlineCodeColor = theme.uiColor(.inlineCodeBackground).withAlphaComponent(0.5)
    view.gutterColor = theme.uiColor(.codeLineNumber)
    view.gutterBorderColor = theme.uiColor(.codeGutterSeparator)
    view.quoteBorderColor = theme.uiColor(.markdownQuoteBorder)
    view.ruleColor = theme.uiColor(.markdownRule)
    let fenced: Bool = { if case .code = block.kind { true } else { false } }()
    var cursor = 0
    view.inlineCodeRanges = block.runs.compactMap { run in
      defer { cursor += run.text.utf16.count }
      guard run.code, !fenced, FileReference.inlineURL(run.text) == nil else { return nil }
      return NSRange(location: cursor, length: run.text.utf16.count)
    }
    let traits = UITraitCollection(preferredContentSizeCategory: category)
    let text = prose.map { ResponseTextStyle.text($0, theme: theme, rasters: rasters, traits: traits) }
      ?? ResponseTextStyle.text(block, theme: theme, rasters: rasters, tableHeader: tableHeader, traits: traits)
    assert(text.length == block.text.utf16.count, "Rendered prose must match its source mapping")
    for match in matches {
      for range in ConversationSearch.renderedRanges(match.range, block: block) {
        text.addAttribute(.backgroundColor, value: theme.uiColor(.primary).withAlphaComponent(
          match.id == highlights.current ? 0.3 : 0.1), range: range)
      }
    }
    let selection = view.originalRange(view.selectedRange)
    view.renderQuoteMarkers(in: text, traits: UITraitCollection(preferredContentSizeCategory: category))
    // A streamed answer edits only its changed tail; anything else measures and decorates again.
    var incremental = false
    if !view.textStorage.isEqual(to: text) {
      incremental = view.show(text)
      view.selectedRange = view.displayRange(selection)
    }
    view.inlineCodeRanges = view.inlineCodeRanges.flatMap(view.displayRanges)
    view.searchRange = view.searchMatch.flatMap { ConversationSearch.renderedRanges($0.range, block: block).first.map(view.displayRange) }
    view.applyFileLinks(coordinator.knownFiles)
    if !incremental { view.invalidateMeasurement() }
    view.accessibilityLabel = block.copyText
    view.accessibilityValue = block.copyText
    view.linkTextAttributes = [:]
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ResponseTextContainer, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width, width > 0 else { return nil }
    let size = uiView.text.fittingSize(width: width)
    return CGSize(width: wrap ? width : size.width, height: max(gutter ? 26 : 0, size.height))
  }
  static func dismantleUIView(_ container: ResponseTextContainer, coordinator: Coordinator) {
    let view = container.text
    coordinator.rendering = nil
    coordinator.fileTask?.cancel()
    coordinator.fileKey = nil
    coordinator.knownFiles = [:]
    view.clearSelection()
    view.attributedText = nil
    view.sourceBlock = nil
    view.prose = nil
    view.source = ""
    view.selectionActions = nil
    view.selectionChanged = nil
    view.searchMatch = nil
    view.searchRange = nil
    view.searchAlign = nil
    view.openNote = nil
    view.openFile = nil
    view.openFolder = nil
    view.openQuote = nil
    view.quoteAlign = nil
    view.quoteHighlights = []
    view.quoteRects = []
    view.quoteButtons.forEach { $0.removeFromSuperview() }
    view.quoteButtons = []
    view.quoteInsertions = []
    view.delegate = nil
  }
  final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard let view = gestureRecognizer.view as? ResponseTextView, view.selectedRange.length == 0,
        !(touch.view is UIControl) else { return false }
      return view.quote(at: touch.location(in: view)) != nil
    }
    @objc func openQuote(_ gesture: UITapGestureRecognizer) {
      guard let view = gesture.view as? ResponseTextView, let mark = view.quote(at: gesture.location(in: view)) else { return }
      view.selectionChanged?()
      view.openQuote?(mark)
    }
    var rendering: Rendering?
    var fileTask: Task<Void, Never>?
    var fileKey: String?
    var knownFiles: [String: FileLinkTarget] = [:]
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
      if case .link(let url) = textItem.content, let path = FileReference.path(url) {
        let folder = FileReference.isFolder(url)
        return UIAction(title: folder ? "Abrir pasta" : "Abrir arquivo") { [weak textView] _ in
          guard let view = textView as? ResponseTextView else { return }
          view.selectionChanged?()
          if folder, let openFolder = view.openFolder { openFolder(path) } else { view.openFile?(path) }
        }
      }
      if case .link(let url) = textItem.content, let resource = ResourceLink.id(from: url) {
        return UIAction(title: "Abrir recurso") { [weak textView] _ in
          (textView as? ResponseTextView)?.selectionChanged?()
          ResourceLinks.open(resource)
        }
      }
      guard case .link(let url) = textItem.content, url.scheme == "opencode-markdown" else { return defaultAction }
      return UIAction(title: "Abrir nota") { [weak textView] _ in
        guard let view = textView as? ResponseTextView else { return }
        view.selectionChanged?()
        view.openNote?(String(url.path.dropFirst()).removingPercentEncoding ?? "")
      }
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      guard textView.selectedRange.length > 0 else { return }
      (textView as? ResponseTextView)?.selectionChanged?()
    }
    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      guard let view = textView as? ResponseTextView, let actions = view.selectionActions,
        let block = view.sourceBlock,
        let quote = ChatQuote.selection(
          source: view.source, block: block, range: view.originalRange(range),
          messageID: view.messageID, partID: view.partID)
      else { return UIMenu(children: suggestedActions) }
      let custom = UIMenu(
        options: .displayInline,
        children: [
          UIAction(title: "Comentar") { [weak view] _ in
            view?.clearSelection()
            actions.comment(quote)
          },
          UIAction(title: "Pergunta paralela") { [weak view] _ in
            view?.clearSelection()
            actions.sideQuestion(quote.text)
          },
        ])
      return UIMenu(
        children: Array(suggestedActions.prefix(1)) + [custom] + suggestedActions.dropFirst())
    }
  }
  struct Rendering: Equatable {
    let block: MarkdownBlock
    let prose: MarkdownProse?
    let theme: String
    let matches: [ConversationMatch]
    let current: String?
    let gutter: Bool
    let wrap: Bool
    let tableHeader: Bool
    let contentSize: String
    let quotes: [ResponseQuoteHighlight]
    let formulas: Int
  }
}

struct ResponseMarkdown: View {
  @Environment(\.appTheme) private var theme
  @Environment(ToastCenter.self) private var toast
  @Environment(\.responseSelection) private var selectionActions
  @Environment(\.responseSelectionChanged) private var selectionChanged
  @Environment(\.conversationSearch) private var highlights
  @Environment(\.displayScale) private var displayScale
  @Environment(\.conversationQuotes) private var quotes
  let text: String
  let messageID: String
  let partID: String
  @State private var blocks: [MarkdownBlock] = []
  @State private var measuredHeight: CGFloat?
  @State private var mounted = false
  @State private var parser = LatestMarkdownParse()
  @State private var rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]
  @State private var rasterTheme = ""
  @State private var note: Note?
  @State private var quoteHighlights: [ResponseQuoteHighlight] = []
  private struct Note: Identifiable { let id: String }
  init(text: String, messageID: String, partID: String) {
    self.text = text
    self.messageID = messageID
    self.partID = partID
    _blocks = State(initialValue: ResponseMarkdownCache.shared.cached(text) ?? [])
  }
  var body: some View {
    ResponseBlocks(blocks: blocks, source: text, messageID: messageID, partID: partID,
      rasters: rasterTheme == theme.id ? rasters : [:], openNote: { note = Note(id: $0) })
    .frame(minHeight: blocks.isEmpty ? measuredHeight : nil)
    .environment(\.responseQuotes, ResponseQuoteContext(highlights: quoteHighlights,
      open: quotes.open, target: quotes.target, active: quotes.active, align: quotes.align))
    .onChange(of: marks, initial: true) { _, _ in resolveQuotes() }
    .onChange(of: quotes.dismissed) { _, _ in resolveQuotes() }
    .onChange(of: blocks) { _, _ in resolveQuotes() }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: { _, height in
      if !blocks.isEmpty { measuredHeight = height }
    }
    .onAppear {
      mounted = true
      parse()
    }
    .onChange(of: text) { _, _ in if mounted { parse() } }
    .onChange(of: theme.id) { _, _ in if mounted { parse() } }
    .onDisappear {
      mounted = false
      parser.cancel()
      // List can recycle a still-measured cell; clearing its blocks creates an empty layout pass.
    }
    .sheet(item: $note) { note in
      if let block = blocks.first(where: { if case .footnote(let id, _) = $0.kind { id == note.id } else { false } }) {
        NavigationStack {
          ScrollView {
            ResponseBlocks(blocks: block.children, source: text, messageID: messageID, partID: partID,
              rasters: rasters, openNote: { self.note = Note(id: $0) }).padding(20)
          }
          .background(theme.color(.background))
          .navigationTitle("Nota de rodapé").navigationBarTitleDisplayMode(.inline)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { self.note = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      }
    }
  }
  private var marks: [ChatQuoteMark] {
    quotes.index.marks(messageID: messageID, partID: partID, pending: quotes.pending,
      dismissed: quotes.dismissed, revealing: quotes.revealing)
  }
  private func resolveQuotes() {
    quoteHighlights = marks.compactMap { mark in
      let ranges = ChatQuoteAnchoring.sourceRanges(mark.quote, source: text, blocks: blocks)
      // A revealed dismissed mark only draws its background: no marker reflows the text.
      return ranges.isEmpty ? nil : ResponseQuoteHighlight(mark: mark, ranges: ranges,
        badge: mark.pending || !quotes.dismissed.contains(mark.quote.id))
    }
  }
  private func parse() {
    let source = text
    // Recycling must not insert an empty row and then reflow it after another parse.
    if let cached = ResponseMarkdownCache.shared.cached(source) {
      blocks = cached
    }
    parser.publish = { landed in
      rasters = landed.rasters
      rasterTheme = landed.theme
      blocks = landed.blocks
    }
    parser.request(source, theme: theme, scale: displayScale)
  }
}

/// Parses the newest text of one response. A newer text never cancels the parse in flight: during a fast
/// stream that cancelled every parse before it landed, so nothing published until the stream paused. It
/// runs once the current parse lands, skipping the texts in between. A landed parse that a newer text
/// already superseded publishes only when nothing did for `interval`, so the text keeps advancing without
/// rendering twice per parse.
@MainActor final class LatestMarkdownParse {
  struct Landed {
    let source: String
    let blocks: [MarkdownBlock]
    let rasters: [ResponseFormulaKey: ResponseFormulaRaster]
    let theme: String
  }
  private var next: (source: String, theme: AppTheme, scale: CGFloat)?
  private var running = false
  private var published = ContinuousClock.now
  private let interval: Duration
  var publish: ((Landed) -> Void)?

  init(interval: Duration = .milliseconds(100)) {
    self.interval = interval
  }

  func request(_ source: String, theme: AppTheme, scale: CGFloat) {
    next = (source, theme, scale)
    guard !running else { return }
    running = true
    Task {
      while let request = next {
        next = nil
        let parsed = await ResponseMarkdownCache.shared.parse(request.source)
        let images = await ResponseFormulas.shared.rasters(
          parsed, theme: request.theme.id, color: request.theme.value(.markdownBody), scale: request.scale)
        guard next == nil || published.duration(to: .now) >= interval else { continue }
        published = .now
        publish?(Landed(source: request.source, blocks: parsed, rasters: images, theme: request.theme.id))
      }
      running = false
    }
  }

  func cancel() {
    next = nil
    publish = nil
  }
}

/// SwiftUI stacks query every hosted view for text baselines while placing children. A `UITextView`
/// answers with a full TextKit layout on each pass, uncached by `fittingSize`; this neutral host has no
/// baseline, so measurement remains the only text layout. Response blocks never align by baseline.
final class ResponseTextContainer: UIView {
  let text: ResponseTextView
  init(_ text: ResponseTextView) {
    self.text = text
    super.init(frame: .zero)
    isOpaque = false
    addSubview(text)
  }
  required init?(coder: NSCoder) { nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    text.frame = bounds
  }
  override var forFirstBaselineLayout: UIView { self }
  override var forLastBaselineLayout: UIView { self }
  // Quote badges extend beyond the text bounds.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    text.point(inside: convert(point, to: text), with: event)
  }
}
