import Foundation
import Markdown

/// Inline HTML tags rendered as styling. Any other tag, and a known tag without its closing sibling, stays literal
/// so no content is hidden.
enum HTMLInlineTag: Equatable {
  case small, superscript, code, strong, emphasis, underline, strikethrough, lineBreak

  struct Token: Equatable {
    let tag: HTMLInlineTag
    let name: String
    let closing: Bool
  }

  static func parse(_ html: String) -> Token? {
    guard let match = expression.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)) else { return nil }
    let text = html as NSString
    let closing = match.range(at: 1).location != NSNotFound
    let name = text.substring(with: match.range(at: 2)).lowercased()
    let attributes = match.range(at: 3).location != NSNotFound
    let tag: HTMLInlineTag? = switch name {
    case "sub", "small": .small
    case "sup": .superscript
    case "code", "kbd": .code
    case "b", "strong": .strong
    case "i", "em": .emphasis
    case "u", "ins": .underline
    case "s", "del", "strike": .strikethrough
    case "br": .lineBreak
    default: nil
    }
    guard let tag, !(closing && (attributes || tag == .lineBreak)) else { return nil }
    return Token(tag: tag, name: name, closing: closing)
  }

  /// The sibling that closes the opening tag at `index`, skipping nested pairs of the same name.
  static func closing(_ token: Token, in nodes: [any Markup], after index: Int) -> Int? {
    var depth = 0
    for position in (index + 1)..<nodes.count {
      guard let html = nodes[position] as? InlineHTML, let other = parse(html.rawHTML), other.name == token.name else { continue }
      if !other.closing { depth += 1; continue }
      if depth == 0 { return position }
      depth -= 1
    }
    return nil
  }

  private static let expression = try! NSRegularExpression(pattern: #"^<(/)?([A-Za-z][A-Za-z0-9]*)(\s+[^<>]*?)?\s*/?>$"#)
}
