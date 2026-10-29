import AppKit
import OpenCodeKit
import SwiftUI

/// The latest landed Markdown parse of each text part, like the iPhone's `TranscriptParses`: a part keeps its
/// previous blocks while a newer text parses (so a streamed answer never empties), parses latest-wins, and the
/// shared `ResponseMarkdownCache` (highlight.js colors, measured formulas) does the work off the main thread.
@MainActor final class MacTranscriptParses {
  struct Result {
    var source: String
    let blocks: [MarkdownBlock]
    let sections: [MarkdownSection]
    var rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]
    init(source: String, blocks: [MarkdownBlock], rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]) {
      self.source = source
      self.blocks = blocks
      sections = MarkdownBlocks.sections(blocks)
      self.rasters = rasters
    }
  }
  private var results: [String: Result] = [:]
  private var next: [String: String] = [:]
  private var running: Set<String> = []
  private var published: [String: ContinuousClock.Instant] = [:]
  /// A parse landed with different blocks: the items must be rebuilt.
  var landed: () -> Void = {}
  /// Formula images landed for blocks already shown.
  var rasterized: () -> Void = {}
  var theme = AppTheme.selected
  var scale: CGFloat = 2

  func parsed(_ part: TranscriptPart) -> Result? {
    if let result = results[part.partID] { return result }
    guard let cached = ResponseMarkdownCache.shared.cached(part.source) else { return nil }
    let result = Result(source: part.source, blocks: cached)
    results[part.partID] = result
    return result
  }

  func blocks(_ part: TranscriptPart) -> [MarkdownBlock]? { parsed(part)?.blocks }
  func rasters(_ partID: String) -> [ResponseFormulaKey: ResponseFormulaRaster] { results[partID]?.rasters ?? [:] }

  /// Parses on the spot, without highlighting or formula metrics, so a place can be laid out before its first
  /// frame; the full parse replaces it. True when it parsed.
  func parseNow(_ part: TranscriptPart) -> Bool {
    guard results[part.partID] == nil else { return false }
    results[part.partID] = Result(source: part.source, blocks: MarkdownBlocks.parse(part.source))
    request(part)
    return true
  }

  /// Starts (or supersedes) the parse of the part's current text. Intermediate results of a fast stream
  /// publish at most every 100 ms, as on the iPhone.
  func request(_ part: TranscriptPart) {
    next[part.partID] = part.source
    guard running.insert(part.partID).inserted else { return }
    let id = part.partID
    Task {
      while let source = next[id] {
        next[id] = nil
        let blocks = await ResponseMarkdownCache.shared.parse(source)
        let images = await ResponseFormulas.shared.rasters(
          blocks, theme: theme.id, color: theme.value(.markdownBody), scale: scale)
        if next[id] != nil, let last = published[id], last.duration(to: .now) < .milliseconds(100) { continue }
        published[id] = .now
        land(id, source: source, blocks: blocks, rasters: images)
      }
      running.remove(id)
    }
  }

  private func land(_ id: String, source: String, blocks: [MarkdownBlock],
    rasters: [ResponseFormulaKey: ResponseFormulaRaster])
  {
    if let previous = results[id], previous.blocks == blocks {
      results[id]?.source = source
      guard previous.rasters != rasters else { return }
      results[id]?.rasters = rasters
      rasterized()
      return
    }
    results[id] = Result(source: source, blocks: blocks, rasters: rasters)
    landed()
  }

  func restyle(_ parts: [TranscriptPart]) {
    for part in parts { request(part) }
  }
}

/// The iPhone's `ResponseTextStyle` at desktop density: the same roles, sizes from `AppTextStyle` on macOS, and
/// formula images from the shared SwaTeX rasters.
@MainActor enum MacResponseTextStyle {
  static let quoteLevel: CGFloat = 14.8

  static func font(_ style: AppTextStyle, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> NSFont {
    monospaced ? .monospacedSystemFont(ofSize: style.size - 1, weight: weight) : .systemFont(ofSize: style.size, weight: weight)
  }

  static func lineHeight(_ style: AppTextStyle) -> CGFloat {
    style == .body || style == .message ? 20 : ceil(style.size * 1.35)
  }

  static func text(_ block: MarkdownBlock, theme: AppTheme, rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:],
    tableHeader: Bool = false) -> NSMutableAttributedString
  {
    let result = NSMutableAttributedString()
    let heading: Int? = { if case .heading(let level) = block.kind { level } else { nil } }()
    let code: Bool = { if case .code = block.kind { true } else { false } }()
    let summary: Bool = { if case .details = block.kind { true } else { false } }()
    let note = block.runs.contains { $0.small } && block.runs.allSatisfy { $0.small || $0.text.allSatisfy(\.isWhitespace) }
    for run in block.runs {
      let regular: AppTextStyle = heading.map { [.title, .heading, .message, .secondary, .secondary, .secondary][min(5, max(0, $0 - 1))] }
        ?? (run.code || code || block.kind == .table ? .secondary : .body)
      let style: AppTextStyle = run.superscript ? .footnote
        : run.small ? (regular == .title ? .message : [.secondary, .caption].contains(regular) ? .caption : .secondary)
        : regular
      let weight: NSFont.Weight = heading != nil || run.strong || tableHeader || run.syntax == .function ? .semibold
        : summary ? .medium : .regular
      let base = font(style, weight: weight, monospaced: run.code || code)
      let font = run.emphasis
        ? NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic)),
          size: base.pointSize) ?? base
        : base
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = lineHeight(note ? style : heading == nil ? .body : style)
      if let marker = block.marker {
        let width = max(24, CGFloat(marker.width))
        paragraph.headIndent = width
        paragraph.firstLineHeadIndent = marker.first ? 0 : width
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: width)]
        paragraph.defaultTabInterval = width
      }
      if block.kind == .table {
        paragraph.alignment = switch block.alignment { case .leading: .left; case .center: .center; case .trailing: .right }
      }
      let role: ThemeRole = code ? run.syntax.map(syntaxRole) ?? .codeText
        : run.code ? .inlineCode
        : block.quoteDepth > 0 ? .markdownQuote
        : heading != nil ? .markdownHeading
        : run.small ? .textSecondary
        : run.strong ? .markdownStrong
        : block.kind == .table ? (tableHeader ? .tableHeaderText : .tableText) : .markdownBody
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .paragraphStyle: paragraph, .foregroundColor: theme.nsColor(role),
      ]
      if run.code, !code { attributes[.backgroundColor] = theme.nsColor(.codeSurface) }
      if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if run.superscript { attributes[.baselineOffset] = 5 }
      if let link = run.link, let url = URL(string: link),
        ["http", "https", "mailto", "tel", "sms", "opencode-markdown", ResourceLink.scheme].contains(url.scheme)
      {
        attributes[.link] = url
        attributes[.foregroundColor] = theme.nsColor(.markdownLink)
      }
      if let link = run.link, let path = FileReference.local(link) {
        attributes[.link] = FileReference.link(path.removingPercentEncoding ?? path)
        attributes[.foregroundColor] = theme.nsColor(.markdownLink)
      }
      if run.code, !code, run.link == nil, let url = FileReference.inlineURL(run.text) {
        attributes[.link] = url
        attributes[.foregroundColor] = theme.nsColor(.inlineCode)
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attributes[.underlineColor] = theme.nsColor(.inlineCode).withAlphaComponent(0.25)
      }
      if let formula = run.formula, let metrics = formula.metrics {
        let attachment = NSTextAttachment()
        if let raster = rasters[ResponseFormulaKey(formula)], let image = NSImage(data: raster.png) {
          image.size = CGSize(width: metrics.width, height: metrics.height)
          attachment.image = image
        }
        attachment.bounds = CGRect(x: 0, y: metrics.baseline - metrics.height, width: metrics.width, height: metrics.height)
        attributes[.attachment] = attachment
      }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    if let checked = block.marker?.checked, block.marker?.first == true, result.length > 0 {
      result.addAttribute(.foregroundColor, value: theme.nsColor(checked ? .markdownTask : .markdownBody),
        range: NSRange(location: 0, length: 1))
    }
    if block.marker?.first == true, let tab = result.string.firstIndex(of: "\t") {
      result.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: AppTextStyle.body.size, weight: .regular),
        range: NSRange(result.string.startIndex..<tab, in: result.string))
    }
    return result
  }

  /// Prose segments joined as paragraphs of one text, unit for unit with `prose.block`.
  static func text(_ prose: MarkdownProse, theme: AppTheme,
    rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]) -> NSMutableAttributedString
  {
    let result = NSMutableAttributedString()
    for (index, segment) in prose.segments.enumerated() {
      let part = segment.kind == .rule ? rule() : text(segment, theme: theme, rasters: rasters)
      let extra = CGFloat(segment.indent) + CGFloat(segment.quoteDepth) * quoteLevel
      let first = (part.string as NSString).range(of: "\n").location
      let lead = NSRange(location: 0, length: first == NSNotFound ? part.length : first + 1)
      part.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: part.length)) { value, range, _ in
        guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.firstLineHeadIndent += extra
        style.headIndent += extra
        style.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + extra) }
        part.addAttribute(.paragraphStyle, value: style, range: range)
      }
      if index > 0, lead.length > 0 {
        part.enumerateAttribute(.paragraphStyle, in: lead) { value, range, _ in
          guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
          style.paragraphSpacingBefore = CGFloat(prose.spacing[index])
          part.addAttribute(.paragraphStyle, value: style, range: range)
        }
      }
      if index > 0 {
        let attributes = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil)
          : [.font: font(.body)]
        result.append(NSAttributedString(string: "\n", attributes: attributes))
      }
      result.append(part)
    }
    return result
  }

  private static func rule() -> NSMutableAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 1
    paragraph.maximumLineHeight = 1
    return NSMutableAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: paragraph])
  }

  static func syntaxRole(_ syntax: MarkdownSyntax) -> ThemeRole {
    switch syntax {
    case .keyword: .syntaxKeyword
    case .string: .syntaxString
    case .comment: .syntaxComment
    case .function: .syntaxFunction
    case .property: .syntaxProperty
    case .type: .syntaxType
    case .constant: .syntaxConstant
    case .number: .syntaxNumber
    case .variable: .syntaxVariable
    case .punctuation: .syntaxPunctuation
    case .operator: .syntaxOperator
    case .added: .syntaxAdded
    case .removed: .syntaxRemoved
    }
  }

  /// A block's runs as a SwiftUI string (code, table cells), with the same roles.
  static func attributed(_ block: MarkdownBlock, theme: AppTheme, tableHeader: Bool = false) -> AttributedString {
    (try? AttributedString(text(block, theme: theme, tableHeader: tableHeader), including: \.appKit))
      ?? AttributedString(block.text)
  }
}

/// A response's prose: one selectable TextKit 2 text view across its paragraphs, headings, list items, quotes and
/// rules, which draws the quote borders and rules itself. Links to files open Arquivos; a selection offers
/// Copiar, Comentar (a quote attached to the next prompt) and Pergunta paralela (about the passage).
final class MacResponseTextView: NSTextView {
  var prose: MarkdownProse?
  var part: TranscriptPart?
  weak var context: MacTranscriptContext?
  /// Outside a transcript (a Markdown file in Arquivos) the theme comes from the host instead.
  var standaloneTheme: AppTheme?
  private var quoteRanges: [(NSRange, Int)] = []
  private var ruleRanges: [NSRange] = []
  private var quoteMap = QuoteTextMap()
  private var highlights: [ResponseQuoteHighlight] = []

  convenience init() {
    self.init(usingTextLayoutManager: true)
    isEditable = false
    isSelectable = true
    isRichText = true
    drawsBackground = false
    textContainerInset = .zero
    textContainer?.lineFragmentPadding = 0
    textContainer?.widthTracksTextView = true
    isVerticallyResizable = false
    isHorizontallyResizable = false
    linkTextAttributes = [.cursor: NSCursor.pointingHand]
    setAccessibilityRole(.staticText)
  }

  func show(_ text: NSAttributedString, prose: MarkdownProse, theme: AppTheme) {
    let selection = quoteMap.original(selectedRange())
    self.prose = prose
    let decorated = NSMutableAttributedString(attributedString: text)
    highlights = (part.flatMap { context?.responseQuotes($0) } ?? []).compactMap { highlight in
      let ranges = highlight.ranges.flatMap { ConversationSearch.renderedRanges($0, block: prose.block) }
      let ending = highlight.ranges.last.map {
        !ConversationSearch.renderedRanges(NSRange(location: NSMaxRange($0) - 1, length: 1), block: prose.block).isEmpty
      } ?? false
      return ranges.isEmpty ? nil : ResponseQuoteHighlight(mark: highlight.mark, ranges: ranges, badge: highlight.badge && ending)
    }
    for highlight in highlights {
      for range in highlight.ranges where NSMaxRange(range) <= decorated.length {
        decorated.addAttributes([
          .backgroundColor: theme.nsColor(.quoteHighlight).withAlphaComponent(context?.quotes.active == highlight.mark.id ? 0.28 : 0.12),
          .underlineStyle: NSUnderlineStyle.single.rawValue,
          .underlineColor: theme.nsColor(.quoteUnderline).withAlphaComponent(0.4),
        ], range: range)
      }
    }
    quoteMap = QuoteTextMap(highlights.filter(\.badge).compactMap { highlight in
      highlight.ranges.last.map { QuoteTextMap.Marker(id: highlight.mark.id, number: highlight.mark.number, offset: NSMaxRange($0)) }
    })
    for insertion in quoteMap.insertions {
      decorated.insert(NSAttributedString(string: String(insertion.marker.number), attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .baselineOffset: 6,
        .foregroundColor: theme.nsColor(.quoteBadge),
      ]), at: insertion.range.location)
    }
    quoteRanges = zip(prose.segments, prose.ranges).compactMap { $0.quoteDepth > 0 ? (quoteMap.display($1), $0.quoteDepth) : nil }
    ruleRanges = zip(prose.segments, prose.ranges).compactMap { $0.kind == .rule ? quoteMap.display($1) : nil }
    let selected = theme.nsColor(.primary).withAlphaComponent(0.28)
    if selectedTextAttributes[.backgroundColor] as? NSColor != selected {
      selectedTextAttributes = [.backgroundColor: selected]
    }
    if let storage = textStorage, !storage.isEqual(to: decorated) {
      replace(storage, with: decorated)
      if selection.length > 0, NSMaxRange(selection) <= text.length { setSelectedRange(quoteMap.display(selection)) }
    }
    needsDisplay = true
  }

  /// A streamed answer only grows at its end: when everything before the last shown paragraph is unchanged,
  /// only that paragraph and what follows are replaced, so TextKit lays out just the tail again.
  private func replace(_ storage: NSTextStorage, with text: NSAttributedString) {
    let old = storage.string as NSString
    let cut = old.length > 0 ? old.paragraphRange(for: NSRange(location: old.length - 1, length: 0)).location : 0
    guard cut > 0, cut <= text.length,
      storage.attributedSubstring(from: NSRange(location: 0, length: cut))
        .isEqual(to: text.attributedSubstring(from: NSRange(location: 0, length: cut)))
    else {
      storage.setAttributedString(text)
      return
    }
    storage.replaceCharacters(in: NSRange(location: cut, length: old.length - cut),
      with: text.attributedSubstring(from: NSRange(location: cut, length: text.length - cut)))
  }

  /// The laid-out height at this width.
  func fittingHeight(width: CGFloat) -> CGFloat {
    if frame.width != width { frame.size.width = width }
    // Setting the container's size, even to the same value, lays the whole text out again: a streamed answer
    // would be laid out from its start on every measure.
    let size = CGSize(width: width, height: .greatestFiniteMagnitude)
    if textContainer?.size != size { textContainer?.size = size }
    guard let manager = textLayoutManager else { return 0 }
    manager.ensureLayout(for: manager.documentRange)
    return ceil(manager.usageBoundsForTextContainer.height)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let theme = context?.theme ?? standaloneTheme else { return }
    for (range, depth) in quoteRanges {
      guard let rect = rect(for: range) else { continue }
      theme.nsColor(.borderStrong).setFill()
      for level in 0..<depth {
        NSRect(x: CGFloat(level) * MacResponseTextStyle.quoteLevel, y: rect.minY, width: 2, height: rect.height).fill()
      }
    }
    for range in ruleRanges {
      guard let rect = rect(for: range) else { continue }
      theme.nsColor(.borderStrong).setFill()
      NSRect(x: 0, y: rect.midY, width: bounds.width, height: 1).fill()
    }
  }

  private func rect(for range: NSRange) -> NSRect? {
    guard let manager = textLayoutManager, let content = manager.textContentManager,
      let start = content.location(content.documentRange.location, offsetBy: range.location),
      let end = content.location(start, offsetBy: range.length),
      let textRange = NSTextRange(location: start, end: end) else { return nil }
    var union: NSRect?
    manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
      union = union.map { $0.union(frame) } ?? frame
      return true
    }
    return union
  }

  func quoteTop(_ id: String) -> CGFloat? {
    highlights.first { $0.mark.quote.id == id }?.ranges.first.flatMap { rect(for: quoteMap.display($0))?.minY }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let wasSelected = selectedRange().length > 0
    let index = characterIndexForInsertion(at: point)
    let link = index < (textStorage?.length ?? 0) && textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
    super.mouseDown(with: event)
    guard !wasSelected, !link, selectedRange().length == 0, event.clickCount == 1 else { return }
    if let insertion = quoteMap.insertions.first(where: { rect(for: $0.range)?.insetBy(dx: -5, dy: -5).contains(point) == true }),
      let mark = highlights.first(where: { $0.mark.id == insertion.marker.id })?.mark {
      context?.quotes.open?(mark)
      return
    }
    let original = quoteMap.original(NSRange(location: index, length: 0)).location
    if let mark = highlights.first(where: { $0.ranges.contains { NSLocationInRange(original, $0) } })?.mark {
      context?.quotes.open?(mark)
    }
  }

  override func accessibilityChildren() -> [Any]? {
    let markers: [NSAccessibilityElement] = quoteMap.insertions.compactMap { insertion in
      guard let rect = rect(for: insertion.range), let window,
        let mark = highlights.first(where: { $0.mark.id == insertion.marker.id })?.mark else { return nil }
      let element = MacQuoteAccessibility()
      element.setAccessibilityRole(.button)
      element.setAccessibilityLabel("Citação \(mark.number)")
      element.setAccessibilityValue(mark.pending ? "rascunho" : "enviada")
      element.setAccessibilityIdentifier("quote-marker-" + mark.id)
      element.setAccessibilityParent(self)
      element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
      element.press = { [weak self] in self?.context?.quotes.open?(mark) }
      return element
    }
    return (super.accessibilityChildren() ?? []) + markers
  }

  override func clicked(onLink link: Any, at charIndex: Int) {
    guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
    if let context { return context.open(url) }
    if FileReference.path(url) == nil { NSWorkspace.shared.open(url) }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    if selectedRange().length > 0 {
      menu.addItem(withTitle: "Copiar", action: #selector(copy(_:)), keyEquivalent: "")
      if context != nil, quote() != nil {
        menu.addItem(withTitle: "Comentar…", action: #selector(comment), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pergunta paralela…", action: #selector(sideQuestion), keyEquivalent: "").target = self
      }
    }
    menu.addItem(withTitle: "Selecionar tudo", action: #selector(selectAll(_:)), keyEquivalent: "")
    return menu
  }

  /// Copies the Markdown of the selection (paragraphs, one list item per line), like the iPhone.
  override func copy(_ sender: Any?) {
    guard let prose, selectedRange().length > 0 else { return super.copy(sender) }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prose.block.copyText(in: quoteMap.original(selectedRange())), forType: .string)
  }

  private func quote() -> ChatQuote? {
    guard let prose, let part else { return nil }
    return ChatQuote.selection(source: part.source, block: prose.block, range: quoteMap.original(selectedRange()),
      messageID: part.messageID, partID: part.partID)
  }

  @objc private func comment() {
    guard let quote = quote() else { return }
    setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    context?.comment(quote)
  }

  @objc private func sideQuestion() {
    guard let quote = quote() else { return }
    setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    context?.sideQuestion(quote.text)
  }

  override func keyDown(with event: NSEvent) {
    if context?.scrollKey(event) == true { return }
    super.keyDown(with: event)
  }
}

private final class MacQuoteAccessibility: NSAccessibilityElement {
  var press: () -> Void = {}
  override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// Code and table cells keep the same source mapping, selection and numbered quote actions as prose.
struct MacSelectableBlock: NSViewRepresentable {
  let block: MarkdownBlock
  let part: TranscriptPart
  let transcript: MacTranscriptContext
  var tableHeader = false
  func makeNSView(context: Context) -> MacResponseTextView { MacResponseTextView() }
  func updateNSView(_ view: MacResponseTextView, context: Context) {
    view.context = transcript
    view.part = part
    // Reading this observable value updates this cell only when its marks change.
    _ = transcript.quotes
    view.show(MacResponseTextStyle.text(block, theme: transcript.theme, tableHeader: tableHeader),
      prose: MarkdownProse([block]), theme: transcript.theme)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacResponseTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: nsView.fittingHeight(width: width))
  }
}

/// Markdown outside a conversation (a file in Arquivos), with the chat's renderer: the shared parse
/// (`ResponseMarkdownCache`: highlight.js colors, measured formulas), prose in the transcript's text view and the
/// transcript's block views.
struct MacMarkdownText: View {
  @Environment(\.appTheme) private var theme
  let text: String
  @State private var sections: [MarkdownSection] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(sections) { section in
        switch section {
        case .prose(let prose): MacStandaloneProse(prose: prose, theme: theme)
        case .block(let block):
          switch block.kind {
          case .code(let language): MacCodeBlock(block: block, language: language)
          case .table: MacTable(block: block)
          case .formula: block.runs.first?.formula.map { MacFormula(formula: $0) }
          default: MacBlockText(blocks: [block])
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: text) {
      sections = MarkdownBlocks.sections(MarkdownBlocks.parse(text))
      sections = MarkdownBlocks.sections(await ResponseMarkdownCache.shared.parse(text))
    }
  }
}

/// One prose run in its selectable text view, sized to its width.
private struct MacStandaloneProse: NSViewRepresentable {
  let prose: MarkdownProse
  let theme: AppTheme

  func makeNSView(context: Context) -> MacResponseTextView { MacResponseTextView() }

  func updateNSView(_ view: MacResponseTextView, context: Context) {
    view.standaloneTheme = theme
    view.show(MacResponseTextStyle.text(prose, theme: theme), prose: prose, theme: theme)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MacResponseTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: nsView.fittingHeight(width: width))
  }
}
