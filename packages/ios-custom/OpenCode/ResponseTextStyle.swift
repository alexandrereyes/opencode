import OpenCodeKit
import UIKit

@MainActor enum ResponseTextStyle {
  static func text(_ block: MarkdownBlock, theme: AppTheme,
    rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:], tableHeader: Bool = false,
    traits: UITraitCollection? = nil) -> NSMutableAttributedString {
    let result = NSMutableAttributedString()
    let heading: Int? = { if case .heading(let level) = block.kind { level } else { nil } }()
    let code: Bool = { if case .code = block.kind { true } else { false } }()
    let summary: Bool = { if case .details = block.kind { true } else { false } }()
    // A paragraph wholly in `<sub>`/`<small>` (a sources note) also gets the smaller line height.
    let note = block.runs.contains { $0.small } && block.runs.allSatisfy { $0.small || $0.text.allSatisfy(\.isWhitespace) }
    for run in block.runs {
      let regular: AppTextStyle = heading.map { [.title, .heading, .message, .secondary, .secondary, .secondary][min(5, max(0, $0 - 1))] }
        ?? (run.code || code || block.kind == .table ? .secondary : .body)
      let style: AppTextStyle = run.superscript ? .footnote
        : run.small ? (regular == .title ? .message : [.secondary, .caption].contains(regular) ? .caption : .secondary)
        : regular
      let weight: UIFont.Weight = heading != nil || run.strong || tableHeader || run.syntax == .function ? .semibold : summary ? .medium : .regular
      let base = AppTypography.font(style, weight: weight, monospaced: run.code || code, compatibleWith: traits)
      let font = run.emphasis ? UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) ?? base.fontDescriptor, size: base.pointSize) : base
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = AppTypography.lineHeight(note ? style : heading == nil ? .body : style, compatibleWith: traits)
      if let marker = block.marker {
        let width = UIFontMetrics(forTextStyle: .body).scaledValue(for: max(24, marker.width), compatibleWith: traits)
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
        .font: font, .paragraphStyle: paragraph,
        .foregroundColor: theme.uiColor(role),
      ]
      if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if run.superscript { attributes[.baselineOffset] = 6 }
      if let link = run.link, let url = URL(string: link),
        ["http", "https", "mailto", "tel", "sms", "opencode-markdown", ResourceLink.scheme].contains(url.scheme) {
        attributes[.link] = url
        attributes[.foregroundColor] = theme.uiColor(.markdownLink)
      }
      if let link = run.link, let path = FileReference.local(link) {
        attributes[.link] = FileReference.link(path.removingPercentEncoding ?? path)
        attributes[.foregroundColor] = theme.uiColor(.markdownLink)
      }
      if run.code, !code, run.link == nil, let url = FileReference.inlineURL(run.text) {
        attributes[.link] = url
        attributes[.foregroundColor] = theme.uiColor(.inlineCode)
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attributes[.underlineColor] = theme.uiColor(.inlineCode).withAlphaComponent(0.25)
      }
      if let formula = run.formula, let metrics = formula.metrics {
        let attachment = NSTextAttachment()
        if let raster = rasters[ResponseFormulaKey(formula)] {
          attachment.image = UIImage(data: raster.png, scale: raster.scale)
        }
        attachment.bounds = CGRect(x: 0, y: metrics.baseline - metrics.height, width: metrics.width, height: metrics.height)
        attributes[.attachment] = attachment
      }
      result.append(NSAttributedString(string: run.text, attributes: attributes))
    }
    if let checked = block.marker?.checked, block.marker?.first == true, result.length > 0 {
      let role: ThemeRole = checked ? .markdownTask : .markdownBody
      result.addAttribute(.foregroundColor, value: theme.uiColor(role), range: NSRange(location: 0, length: 1))
    }
    if block.marker?.first == true, let tab = result.string.firstIndex(of: "\t") {
      let font = AppTypography.font(.body, weight: .regular, compatibleWith: traits)
      result.addAttribute(.font, value: UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
        range: NSRange(result.string.startIndex..<tab, in: result.string))
    }
    return result
  }

  /// Width of one quotation level: its 2 pt border and the 12.8 pt gap before the text.
  static let quoteLevel: CGFloat = 14.8

  /// Prose segments joined as paragraphs of one text, matching `prose.block` unit for unit. Spacing,
  /// nesting and quotation levels become paragraph attributes; borders and rules are drawn by the view.
  static func text(_ prose: MarkdownProse, theme: AppTheme,
    rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:], traits: UITraitCollection? = nil) -> NSMutableAttributedString {
    let result = NSMutableAttributedString()
    for (index, segment) in prose.segments.enumerated() {
      let part = segment.kind == .rule ? rule(traits: traits) : text(segment, theme: theme, rasters: rasters, traits: traits)
      let extra = segment.indent + CGFloat(segment.quoteDepth) * quoteLevel
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
          style.paragraphSpacingBefore = prose.spacing[index]
          part.addAttribute(.paragraphStyle, value: style, range: range)
        }
      }
      if index > 0 {
        // The separator ends the previous paragraph and keeps its attributes.
        let attributes = result.length > 0 ? result.attributes(at: result.length - 1, effectiveRange: nil)
          : part.length > 0 ? part.attributes(at: 0, effectiveRange: nil) : [.font: AppTypography.font(.body, compatibleWith: traits)]
        result.append(NSAttributedString(string: "\n", attributes: attributes))
      }
      result.append(part)
    }
    return result
  }

  /// A one-point line box; the view draws the rule through it.
  private static func rule(traits: UITraitCollection?) -> NSMutableAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 1
    paragraph.maximumLineHeight = 1
    return NSMutableAttributedString(string: " ", attributes: [
      .font: AppTypography.font(.body, compatibleWith: traits).withSize(1), .paragraphStyle: paragraph,
    ])
  }

  private static func syntaxRole(_ syntax: MarkdownSyntax) -> ThemeRole {
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
}
