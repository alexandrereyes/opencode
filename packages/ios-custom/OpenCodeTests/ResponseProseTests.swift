import OpenCodeKit
import SwiftUI
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class ResponseProseTests: XCTestCase {
  private func host(_ text: SelectableResponseText, width: CGFloat = 360) throws -> (UIWindow, ResponseTextView) {
    let window = UIWindow(windowScene: try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    let host = UIHostingController(rootView: text.frame(width: width))
    window.rootViewController = host
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    func response(in parent: UIView) -> ResponseTextView? {
      (parent as? ResponseTextView) ?? parent.subviews.lazy.compactMap { response(in: $0) }.first
    }
    let view = try XCTUnwrap(response(in: host.view))
    view.layoutIfNeeded()
    return (window, view)
  }

  func testEveryFixtureProseRendersItsSourceMappingInBothThemes() throws {
    let source = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "markdown-fixture", withExtension: "md")), encoding: .utf8)
    let prose = MarkdownBlocks.sections(MarkdownBlocks.parse(source)).compactMap { section -> MarkdownProse? in
      if case .prose(let prose) = section { return prose }
      return nil
    }
    XCTAssertGreaterThan(prose.count, 5)
    XCTAssertTrue(prose.contains { $0.segments.count > 5 })
    for id in ["openchamber-dark", "openchamber-light"] {
      let theme = AppTheme.load(id)
      for item in prose {
        let text = ResponseTextStyle.text(item, theme: theme)
        XCTAssertEqual(text.length, item.block.text.utf16.count)
        XCTAssertEqual(text.string, item.block.text)
      }
    }
  }

  func testSelectionAcrossParagraphsHeadingsAndListsCopiesAndQuotesTheWholeRange() throws {
    let source = "Primeiro parágrafo.\n\n## Seção\n\n- Item um\n- Item dois\n\n> Citação.\n\n---\n\nFim."
    guard case .prose(let prose) = MarkdownBlocks.sections(MarkdownBlocks.parse(source)).first else {
      return XCTFail("Expected joined prose")
    }
    var quoted: ChatQuote?
    let text = SelectableResponseText(block: prose.block, messageID: "m", partID: "m:text:0", theme: .selected,
      prose: prose, source: source,
      actions: ResponseSelectionActions(comment: { quoted = $0 }, sideQuestion: { _ in }))
    let (window, view) = try host(text)
    defer { window.isHidden = true; window.rootViewController = nil }
    XCTAssertEqual(view.attributedText.string, prose.block.text)
    XCTAssertEqual(view.accessibilityValue, prose.block.copyText)
    // Indentation and spacing are paragraph attributes, so the whole response is one text.
    let heading = (prose.block.text as NSString).range(of: "Seção")
    let style = view.attributedText.attribute(.paragraphStyle, at: heading.location, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(style?.paragraphSpacingBefore, 20)
    let quote = (prose.block.text as NSString).range(of: "Citação.")
    let quoteStyle = view.attributedText.attribute(.paragraphStyle, at: quote.location, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertEqual(quoteStyle?.headIndent, ResponseTextStyle.quoteLevel)
    XCTAssertNotNil(view.segmentRect(prose.segments.firstIndex { $0.kind == .rule }!))
    // Paragraph → heading → list.
    let start = (prose.block.text as NSString).range(of: "parágrafo").location
    let end = NSMaxRange((prose.block.text as NSString).range(of: "Item dois"))
    view.selectedRange = NSRange(location: start, length: end - start)
    view.copy(nil)
    XCTAssertEqual(UIPasteboard.general.string, "parágrafo.\n\nSeção\n\n•\tItem um\n•\tItem dois")
    let sourceRange = try XCTUnwrap(view.selectionSourceRange)
    XCTAssertEqual((source as NSString).substring(with: sourceRange), "parágrafo.\n\n## Seção\n\n- Item um\n- Item dois")
    let coordinator = SelectableResponseText.Coordinator()
    let menu = try XCTUnwrap(coordinator.textView(view, editMenuForTextIn: view.selectedRange, suggestedActions: []))
    let titles = menu.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { ($0 as? UIAction)?.title }
    XCTAssertEqual(titles, ["Comentar", "Pergunta paralela"])
    XCTAssertNil(quoted)
    let selection = try XCTUnwrap(ChatQuote.selection(source: source, block: prose.block,
      range: view.originalRange(view.selectedRange), messageID: "m", partID: "m:text:0"))
    XCTAssertEqual(selection.text, "parágrafo.\n\nSeção\n\n•\tItem um\n•\tItem dois")
    XCTAssertEqual(selection.anchor?.exact, "parágrafo.\n\n## Seção\n\n- Item um\n- Item dois")
  }

  func testQuoteMarksAndSearchSpanSegmentsOfOneText() throws {
    let source = "Primeiro parágrafo.\n\nSegundo parágrafo."
    let blocks = MarkdownBlocks.parse(source)
    guard case .prose(let prose) = MarkdownBlocks.sections(blocks).first else { return XCTFail("Expected joined prose") }
    let range = NSRange(location: 0, length: prose.block.text.utf16.count)
    let quote = try XCTUnwrap(ChatQuote.selection(source: source, block: prose.block, range: range, messageID: "m", partID: "m:text:0"))
    let mark = ChatQuoteMark(quote: quote, number: 1)
    let message = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(JSONValue.object([
      "id": .string("m"), "type": .string("assistant"), "time": .object(["created": .number(1)]),
      "content": .array([.object(["type": .string("text"), "text": .string(source)])]),
    ])))
    let matches = ConversationSearch.matches("parágrafo", messages: [message])
    XCTAssertEqual(matches.count, 2)
    let partID = try XCTUnwrap(matches.first?.partID)
    let text = SelectableResponseText(block: prose.block, messageID: "m", partID: partID, theme: .selected,
      prose: prose, source: source, highlights: .init(matches: matches, current: matches.last?.id),
      quotesOverride: .init(highlights: [.init(mark: mark, ranges: ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: blocks))]))
    let (window, view) = try host(text)
    defer { window.isHidden = true; window.rootViewController = nil }
    // One marker at the end of the whole quotation, highlights in both paragraphs.
    XCTAssertEqual(view.quoteInsertions.count, 1)
    let rects = view.quoteRects.first.map { $0.1.count } ?? 0
    XCTAssertGreaterThanOrEqual(rects, 2)
    let attributed = try XCTUnwrap(view.attributedText)
    let highlighted = (0..<attributed.length).filter { attributed.attribute(.backgroundColor, at: $0, effectiveRange: nil) != nil }
    XCTAssertEqual(highlighted.count, "parágrafo".utf16.count * 2)
    let current: NSRange? = view.displayRange((prose.block.text as NSString).range(of: "parágrafo", options: .backwards))
    XCTAssertEqual(view.searchRange, current)
  }
}
