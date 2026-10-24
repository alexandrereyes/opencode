import OpenCodeKit
import UIKit

// A token occupies one UTF-16 unit in TextKit. Wire/draft offsets still use its full label.
final class ComposerTokenAttachment: NSTextAttachment {
  let token: ComposerToken
  @MainActor init(_ token: ComposerToken, theme: AppTheme, font: UIFont) {
    self.token = token
    super.init(data: nil, ofType: nil)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font, .foregroundColor: theme.uiColor(token.kind.role),
    ]
    let label = NSAttributedString(string: token.text, attributes: attributes)
    let size = CGSize(width: ceil(label.size().width) + 8, height: ceil(font.lineHeight))
    image = UIGraphicsImageRenderer(size: size).image { _ in
      theme.uiColor(token.kind.role).withAlphaComponent(0.12).setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
      label.draw(at: CGPoint(x: 4, y: 0))
    }
    bounds = CGRect(x: 0, y: font.descender, width: size.width, height: size.height)
    accessibilityLabel = token.text
  }
  required init?(coder: NSCoder) { nil }
}

extension ComposerDocument {
  @MainActor func editorAttributed(theme: AppTheme = .selected, font: UIFont = .preferredFont(forTextStyle: .body)) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text, attributes: [
      .font: font, .foregroundColor: theme.uiColor(.text),
    ])
    for span in validTokens.reversed() {
      result.replaceCharacters(in: span.range, with: NSAttributedString(
        attachment: ComposerTokenAttachment(span.token, theme: theme, font: font)))
    }
    return result
  }

  @MainActor init(editor: NSAttributedString) {
    // One bridged string and NSString lengths keep long, token-heavy drafts linear.
    let source = editor.string as NSString
    let text = NSMutableString()
    var tokens: [ComposerSpan] = []
    editor.enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.length)) { value, range, _ in
      guard let attachment = value as? ComposerTokenAttachment else {
        text.append(source.substring(with: range))
        return
      }
      let start = text.length
      text.append(attachment.token.text)
      tokens.append(.init(start: start, end: text.length, token: attachment.token))
    }
    self.init(text: text as String, tokens: tokens)
  }
}
