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
    for run in block.runs {
      let style: AppTextStyle = run.superscript ? .footnote
        : heading.map { [.title, .heading, .message, .secondary, .secondary, .secondary][min(5, max(0, $0 - 1))] }
          ?? (run.code || code || block.kind == .table ? .secondary : .body)
      let weight: UIFont.Weight = heading != nil || run.strong || block.marker != nil || tableHeader || run.syntax == .function ? .semibold : summary ? .medium : .regular
      let base = AppTypography.font(style, weight: weight, monospaced: run.code || code, compatibleWith: traits)
      let font = run.emphasis ? UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) ?? base.fontDescriptor, size: base.pointSize) : base
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = AppTypography.lineHeight(heading == nil ? .body : style, compatibleWith: traits)
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
        : run.strong ? .markdownStrong
        : block.kind == .table ? (tableHeader ? .tableHeaderText : .tableText) : .markdownBody
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .paragraphStyle: paragraph,
        .foregroundColor: theme.uiColor(role),
      ]
      if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if run.superscript { attributes[.baselineOffset] = 6 }
      if let link = run.link, let url = URL(string: link),
        ["http", "https", "mailto", "tel", "sms", "opencode-markdown"].contains(url.scheme) {
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
      let font = AppTypography.font(.body, weight: .semibold, compatibleWith: traits)
      result.addAttribute(.font, value: UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold),
        range: NSRange(result.string.startIndex..<tab, in: result.string))
    }
    return result
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
