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
      XCTAssertEqual(view.originalRange(NSRange(location: 0, length: attributed.length)).length, block.text.utf16.count)
      XCTAssertEqual(view.textContainerInset.right, 0)
      XCTAssertEqual(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
        ResponseTextStyle.text(block, theme: theme).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
      XCTAssertFalse(view.quoteRects.isEmpty)
      XCTAssertEqual(view.quoteButtons.count, 1)
      let marker = try XCTUnwrap(view.quoteInsertions.first)
      XCTAssertEqual((attributed.attribute(.font, at: marker.range.location, effectiveRange: nil) as? UIFont)?.pointSize,
        AppTextStyle.chrome.size)
      XCTAssertEqual(view.quoteButtons.first?.frame.size, CGSize(width: 44, height: 44))
      let size = view.fittingSize(width: 320)
      view.configureQuotes(.init(highlights: [.init(mark: mark, ranges: ChatQuoteAnchoring.sourceRanges(quote, source: source, blocks: [block]))]), block: block, theme: theme)
      XCTAssertEqual(view.measuredSizes[320], size)
      XCTAssertTrue(view.becomeFirstResponder())
      view.selectedRange = NSRange(location: 0, length: 3)
      XCTAssertNil(view.quote(at: CGPoint(x: 10, y: 10)), "A tap inside the selection keeps the native menu")
      view.clearSelection()
      XCTAssertTrue(view.isSelectable)
      XCTAssertFalse(view.isEditable)
      XCTAssertEqual(view.sourceBlock?.copyText, block.text)
      view.selectedRange = NSRange(location: 0, length: attributed.length)
      view.copy(nil)
      XCTAssertEqual(UIPasteboard.general.string, block.copyText)
    }
  }
  /// A temporary selection never hides a saved quote: outside it, the mark and its number open the comment at once,
  /// and a text that loses the focus keeps no hidden range that would block them.
  func testSelectionElsewhereLetsTheMarkAndItsNumberOpenTheComment() throws {
    let source = "Primeiro trecho marcado aqui. Depois vem um texto comum para selecionar longe da marca."
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
    let marked = (block.text as NSString).range(of: "Primeiro trecho marcado")
    let quote = try XCTUnwrap(ChatQuote.selection(source: source, block: block, range: marked, messageID: "m", partID: "m:text:0"))
    let mark = ChatQuoteMark(quote: quote, number: 1)
    var opened: [String] = []
    let text = SelectableResponseText(block: block, messageID: "m", partID: "m:text:0", theme: AppTheme.load("openchamber-dark"),
      source: source, quotesOverride: .init(highlights: [.init(mark: mark, ranges: [marked])], open: { opened.append($0.id) }))
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
    func center(_ range: NSRange) throws -> CGPoint {
      let rect = try XCTUnwrap(view.textRects(view.displayRange(range)).first)
      return CGPoint(x: rect.midX, y: rect.midY)
    }
    let markPoint = try center(NSRange(location: marked.location + 2, length: 4))
    let selected = view.displayRange((block.text as NSString).range(of: "texto comum"))
    let selectedPoint = try center((block.text as NSString).range(of: "comum"))

    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = selected
    XCTAssertTrue(view.hasSelection)
    XCTAssertEqual(view.quote(at: markPoint)?.id, mark.id, "Uma marca fora da seleção abre com um toque")
    XCTAssertNil(view.quote(at: selectedPoint), "Dentro da seleção, o toque continua nativo")

    // Losing the focus (a tap or drag elsewhere, another text, reuse) drops the hidden range.
    XCTAssertTrue(view.resignFirstResponder())
    XCTAssertEqual(view.selectedRange.length, 0)
    XCTAssertFalse(view.hasSelection)
    // A range UIKit kept without the focus is not a selection either.
    view.selectedRange = selected
    XCTAssertEqual(view.quote(at: markPoint)?.id, mark.id)

    XCTAssertTrue(view.becomeFirstResponder())
    view.selectedRange = selected
    let number = try XCTUnwrap(view.quoteButtons.first)
    XCTAssertTrue(view.hitTest(CGPoint(x: number.frame.midX, y: number.frame.midY), with: nil) === number)
    number.sendActions(for: .touchUpInside)
    XCTAssertEqual(opened, [mark.id], "O número abre o comentário mesmo com uma seleção")
    XCTAssertEqual(view.selectedRange.length, 0)
    XCTAssertFalse(view.isFirstResponder)
    XCTAssertEqual(view.quoteHighlights.map(\.mark.id), [mark.id], "Limpar a seleção não apaga a marcação")
  }
  /// A quote opened from one text ends the selection another text holds, so its sheet does not leave that text with a
  /// selection UIKit no longer shows or extends.
  func testOpeningAQuoteEndsAnotherTextsSelection() throws {
    let theme = AppTheme.load("openchamber-dark")
    let plainSource = "Um parágrafo sem comentário, selecionado antes de abrir a citação."
    let plain = try XCTUnwrap(MarkdownBlocks.parse(plainSource).first)
    let source = "Trecho comentado em outro texto."
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
    let marked = (block.text as NSString).range(of: "Trecho comentado")
    let quote = try XCTUnwrap(ChatQuote.selection(source: source, block: block, range: marked, messageID: "m", partID: "m:text:1"))
    let mark = ChatQuoteMark(quote: quote, number: 1)
    var opened: [String] = []
    let host = UIHostingController(rootView: VStack {
      SelectableResponseText(block: plain, messageID: "m", partID: "m:text:0", theme: theme, source: plainSource)
      SelectableResponseText(block: block, messageID: "m", partID: "m:text:1", theme: theme, source: source,
        quotesOverride: .init(highlights: [.init(mark: mark, ranges: [marked])], open: { opened.append($0.id) }))
    })
    let window = UIWindow(windowScene: try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    window.rootViewController = host
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    defer { window.isHidden = true; window.rootViewController = nil }
    func responses(in parent: UIView) -> [ResponseTextView] {
      [parent as? ResponseTextView].compactMap { $0 } + parent.subviews.flatMap(responses)
    }
    let views = responses(in: host.view)
    let selected = try XCTUnwrap(views.first { $0.partID == "m:text:0" })
    let commented = try XCTUnwrap(views.first { $0.partID == "m:text:1" })
    commented.layoutIfNeeded()
    XCTAssertTrue(selected.becomeFirstResponder())
    selected.selectedRange = NSRange(location: 3, length: 9)
    XCTAssertTrue(selected.hasSelection)
    try XCTUnwrap(commented.quoteButtons.first).sendActions(for: .touchUpInside)
    XCTAssertEqual(opened, [mark.id])
    XCTAssertFalse(selected.isFirstResponder, "A outra seleção termina antes da folha")
    XCTAssertEqual(selected.selectedRange.length, 0)
    XCTAssertEqual(commented.quoteHighlights.map(\.mark.id), [mark.id])
    // Selecting it again starts over from a focused text.
    XCTAssertTrue(selected.becomeFirstResponder())
    selected.selectedRange = NSRange(location: 3, length: 9)
    XCTAssertTrue(selected.hasSelection)
  }
  func testSeveralInlineMarkersPreserveUTF16SourceSelectionAndCopy() throws {
    let source = "Antes 😀 trecho um; depois trecho dois e o fim."
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
    let ranges = ["😀 trecho um", "trecho dois"].map { (block.text as NSString).range(of: $0) }
    let view = ResponseTextView(frame: .zero, textContainer: nil)
    view.sourceBlock = block
    view.quoteHighlights = try ranges.enumerated().map { index, range in
      let quote = try XCTUnwrap(ChatQuote.selection(source: source, block: block, range: range, messageID: "m", partID: "p"))
      return ResponseQuoteHighlight(mark: ChatQuoteMark(quote: quote, number: index + 1), ranges: [range])
    }
    let traits = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
    let text = ResponseTextStyle.text(block, theme: AppTheme.load("openchamber-dark"), traits: traits)
    view.renderQuoteMarkers(in: text, traits: traits)
    view.attributedText = text
    XCTAssertEqual(text.string, "Antes 😀 trecho um1; depois trecho dois2 e o fim.")
    XCTAssertEqual(view.quoteInsertions.count, 2)
    let after = (text.string as NSString).range(of: "depois")
    XCTAssertEqual(text.attribute(.font, at: after.location, effectiveRange: nil) as? UIFont,
      AppTypography.font(.body, compatibleWith: traits))
    for range in ranges {
      XCTAssertEqual(view.originalRange(view.displayRange(range)), range)
    }
    let selected = (text.string as NSString).range(of: "depois trecho dois2")
    view.selectedRange = selected
    view.copy(nil)
    XCTAssertEqual(UIPasteboard.general.string, "depois trecho dois")
    XCTAssertEqual(view.selectionSourceRange, (source as NSString).range(of: "depois trecho dois"))
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
