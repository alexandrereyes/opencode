import OpenCodeKit
import SwiftUI
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class QuoteDecorationTests: XCTestCase {
  func testDecorationsKeepTypographySelectionAndMeasurementCacheInBothThemes() throws {
    let source = "**Uma decisão:** mantenha a seleção e a cópia funcionando mesmo com várias linhas marcadas."
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
    let quote = try XCTUnwrap(ChatQuote.selection(source: source, block: block,
      range: NSRange(location: 0, length: block.text.utf16.count), messageID: "m", partID: "m:text:0"))
    let mark = ChatQuoteMark(quote: quote, number: 1)
    for id in ["openchamber-dark", "openchamber-light"] {
      let theme = AppTheme.load(id)
      let text = SelectableResponseText(block: block, messageID: "m", partID: "m:text:0", theme: theme, source: source,
        quotesOverride: .init(highlights: [.init(mark: mark, ranges: ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: [block]))]))
      let window = UIWindow(windowScene: try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
      let host = UIHostingController(rootView: text)
      window.rootViewController = host
      window.makeKeyAndVisible()
      window.layoutIfNeeded()
      defer { window.isHidden = true; window.rootViewController = nil }
      func response(in parent: UIView) -> ResponseTextView? {
        (parent as? ResponseTextView) ?? parent.subviews.lazy.compactMap { response(in: $0) }.first
      }
      let view = try XCTUnwrap(response(in: host.view))
      view.layoutIfNeeded()
      let attributed = try XCTUnwrap(view.attributedText)
      XCTAssertEqual(attributed.string, block.text)
      XCTAssertEqual(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
        ResponseTextStyle.text(block, theme: theme).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
      XCTAssertFalse(view.quoteRects.isEmpty)
      XCTAssertEqual(view.quoteButtons.count, 1)
      let size = view.fittingSize(width: 320)
      view.configureQuotes(.init(highlights: [.init(mark: mark, ranges: ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: [block]))]), block: block, theme: theme)
      XCTAssertEqual(view.measuredSizes[320], size)
      view.selectedRange = NSRange(location: 0, length: 3)
      XCTAssertNil(view.quote(at: CGPoint(x: 10, y: 10)), "A marked range must not intercept an existing selection")
      XCTAssertTrue(view.isSelectable)
      XCTAssertFalse(view.isEditable)
      XCTAssertEqual(view.sourceBlock?.copyText, block.text)
    }
  }
  func testCodeAndTableSelectionsRetainSourceOffsetsAndQuoteMarks() throws {
    for source in ["```swift\nlet valor = 1\n```", "| Nome |\n| --- |\n| Ação |"] {
      let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
      let selectable = block.table.map { block.cell($0.rows[1][0], alignment: .leading) } ?? block.codeDisplay
      let quote = try XCTUnwrap(ChatQuote.selection(source: source, block: selectable,
        range: NSRange(location: 0, length: selectable.text.utf16.count), messageID: "m", partID: "m:text:0"))
      XCTAssertFalse(ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: [block]).isEmpty)
    }
  }
}
