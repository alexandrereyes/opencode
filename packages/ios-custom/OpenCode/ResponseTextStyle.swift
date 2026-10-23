import OpenCodeKit
import UIKit

@MainActor enum ResponseTextStyle {
  static func text(_ block: MarkdownBlock, theme: AppTheme,
    rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:], tableHeader: Bool = false) -> NSMutableAttributedString {
    let result = NSMutableAttributedString()
    let heading: Int? = { if case .heading(let level) = block.kind { level } else { nil } }()
    let code: Bool = { if case .code = block.kind { true } else { false } }()
    let summary: Bool = { if case .details = block.kind { true } else { false } }()
    for run in block.runs {
      let size: CGFloat = run.superscript ? 12
        : heading.map { [20.0, 18, 16, 14, 14, 14][min(5, max(0, $0 - 1))] }
          ?? (run.code || code || block.kind == .table ? 14 : 16)
      let weight: UIFont.Weight = heading != nil || run.strong || tableHeader || run.syntax == .function ? .semibold : summary ? .medium : .regular
      let base = run.code || code ? UIFont.monospacedSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
      let font = run.emphasis ? UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) ?? base.fontDescriptor, size: size) : base
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = heading == nil ? 26 : size * 1.3
      paragraph.maximumLineHeight = heading == nil ? 0 : size * 1.3
      if let marker = block.marker {
        paragraph.headIndent = marker.width
        paragraph.firstLineHeadIndent = marker.first ? 0 : marker.width
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: marker.width)]
        paragraph.defaultTabInterval = marker.width
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
      let opacity = heading != nil ? 0.95 : run.code && !code ? 0.9 : block.kind == .table && !tableHeader ? 0.9 : 1
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .paragraphStyle: paragraph,
        .foregroundColor: theme.uiColor(role).withAlphaComponent(theme.value(role).opacity * opacity),
      ]
      if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      if run.superscript { attributes[.baselineOffset] = 6 }
      if let link = run.link, let url = URL(string: link),
        ["http", "https", "mailto", "tel", "sms", "opencode-markdown"].contains(url.scheme) { attributes[.link] = url }
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
