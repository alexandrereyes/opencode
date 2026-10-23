import OpenCodeKit
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class MarkdownFileLinkTests: XCTestCase {
  func testExplicitFileLinksAndCodeExistenceNeverChangeCopyOrSelection() throws {
    let source = "[Vídeo](/private/tmp/a.mp4) e `notes.txt` e `missing.txt` e …/a.mp4"
    let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
    for theme in ["openchamber-dark", "openchamber-light"] {
      let text = ResponseTextStyle.text(block, theme: AppTheme.load(theme))
      XCTAssertEqual(FileReference.path(try XCTUnwrap(text.attribute(.link, at: 0, effectiveRange: nil) as? URL)), "/private/tmp/a.mp4")
      let view = ResponseTextView(frame: .zero, textContainer: nil)
      view.sourceBlock = block
      view.attributedText = text
      view.applyFileLinks(["notes.txt"])
      XCTAssertEqual(view.attributedText.string, block.text)
      let notes = (block.text as NSString).range(of: "notes.txt")
      XCTAssertEqual(FileReference.path(try XCTUnwrap(view.attributedText.attribute(.link, at: notes.location, effectiveRange: nil) as? URL)), "notes.txt")
      let missing = (block.text as NSString).range(of: "missing.txt")
      XCTAssertNil(view.attributedText.attribute(.link, at: missing.location, effectiveRange: nil))
      let selection = try XCTUnwrap(block.sourceRange(for: notes))
      XCTAssertEqual((source as NSString).substring(with: selection), "notes.txt")
    }
  }
  func testProseFencesAndEllipsisRemainPlainWhileLocalTableLinksAreInteractive() throws {
    let theme = AppTheme.load("openchamber-dark")
    for source in ["/private/tmp/a.mp4", "`…/a.mp4`", "```\n/private/tmp/a.mp4\n```"] {
      let text = ResponseTextStyle.text(try XCTUnwrap(MarkdownBlocks.parse(source).first), theme: theme)
      XCTAssertNil(text.attribute(.link, at: 0, effectiveRange: nil))
    }
    let table = try XCTUnwrap(MarkdownBlocks.parse("| Arquivo |\n| --- |\n| [Texto](notes.txt) |").first)
    let cell = try XCTUnwrap(table.table?.rows.last?.first)
    let text = ResponseTextStyle.text(table.cell(cell), theme: theme)
    XCTAssertEqual(FileReference.path(try XCTUnwrap(text.attribute(.link, at: 0, effectiveRange: nil) as? URL)), "notes.txt")
    let url = ResponseTextStyle.text(MarkdownBlocks.parse("`https://example.com/image.png` rótulo")[0], theme: theme)
    XCTAssertEqual((url.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.host, "example.com")
  }
}
