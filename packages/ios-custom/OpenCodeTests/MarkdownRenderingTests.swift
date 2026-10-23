import OpenCodeKit
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class MarkdownRenderingTests: XCTestCase {
  func testCodeHighlightUsesNativeSemanticRunsAndKeepsExactSource() async throws {
    let source = "```js\nconst nome = \"ação 😀\";\nconsole.log(nome);\n```"
    let blocks = await ResponseEngines.shared.highlight(MarkdownBlocks.parse(source))
    let block = try XCTUnwrap(blocks.first)
    XCTAssertEqual(block.text, "const nome = \"ação 😀\";\nconsole.log(nome);\n")
    XCTAssertTrue(block.runs.contains { $0.syntax == .keyword && $0.text == "const" })
    XCTAssertTrue(block.runs.contains { $0.syntax == .string && $0.text.contains("ação 😀") })
    let selected = try XCTUnwrap(block.sourceRange(for: (block.text as NSString).range(of: "ação 😀")))
    XCTAssertEqual((source as NSString).substring(with: selected), "ação 😀")
    let unknown = MarkdownBlocks.parse("```linguagem-inexistente\ntexto\n```")
    let fallback = await ResponseEngines.shared.highlight(unknown)
    XCTAssertEqual(fallback, unknown)
  }

  func testMathGeometryAndRasterArePreparedOutsideUIKitAndCopyIsLatex() async throws {
    let blocks = await ResponseFormulas.shared.measure(MarkdownBlocks.parse("Antes $E=mc^2$ depois.\n\n$$\\frac{1}{3}$$"))
    let block = try XCTUnwrap(blocks.first)
    let formula = try XCTUnwrap(block.runs.compactMap(\.formula).first)
    let metrics = try XCTUnwrap(formula.metrics)
    XCTAssertGreaterThan(metrics.width, 20)
    XCTAssertGreaterThan(metrics.height, 10)
    let theme = AppTheme.load("openchamber-dark")
    let rasters = await ResponseFormulas.shared.rasters(blocks, theme: theme.id, color: theme.value(.markdownBody), scale: 3)
    XCTAssertEqual(rasters.count, 2)
    let text = ResponseTextStyle.text(block, theme: theme, rasters: rasters)
    let selected = (block.text as NSString).range(of: "\u{fffc}")
    let attachment = try XCTUnwrap(text.attribute(.attachment, at: selected.location, effectiveRange: nil) as? NSTextAttachment)
    XCTAssertEqual(attachment.bounds.width, metrics.width, accuracy: 0.01)
    XCTAssertNotNil(attachment.image)
    XCTAssertEqual(block.copyText(in: selected), "E=mc^2")
  }

  func testOversizedFormulaFallsBackToSelectableSourceBeforeLayout() async throws {
    let source = #"$$\begin{alignat}{999999999}x\end{alignat}$$"#
    let blocks = await ResponseFormulas.shared.measure(MarkdownBlocks.parse(source))
    XCTAssertNil(blocks.first?.runs.first?.formula)
    XCTAssertTrue(blocks.first?.text.contains("alignat") == true)
  }

  func testHeadingScaleLineRhythmAndTypedRolesInBothThemes() throws {
    for id in ["openchamber-dark", "openchamber-light"] {
      let theme = AppTheme.load(id)
      for (level, size) in [(1, 22.0), (2, 19), (3, 18), (4, 15), (5, 15), (6, 15)] {
        let block = try XCTUnwrap(MarkdownBlocks.parse(String(repeating: "#", count: level) + " Título").first)
        let text = ResponseTextStyle.text(block, theme: theme)
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, size)
      }
      let paragraph = ResponseTextStyle.text(MarkdownBlocks.parse("Corpo **forte** e ~~antigo~~.")[0], theme: theme)
      let style = try XCTUnwrap(paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
      XCTAssertEqual(style.minimumLineHeight, AppTypography.lineHeight(.body))
      XCTAssertEqual(paragraph.attribute(.strikethroughStyle, at: (paragraph.string as NSString).range(of: "antigo").location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }
  }

  func testMermaidRendersSameLibraryWithoutMainThreadOrNetwork() async throws {
    let source = "flowchart TD\n A[Receber] --> B[Publicar]"
    let rendered = await ResponseEngines.shared.diagram(source)
    let svg = try XCTUnwrap(rendered)
    XCTAssertTrue(svg.hasPrefix("<svg"))
    XCTAssertTrue(svg.contains("--diagram-text"))
    XCTAssertTrue(svg.contains("Receber"))
    let portable = ResponseDiagramTheme.export(svg, theme: AppTheme.load("openchamber-dark"))
    XCTAssertFalse(portable.contains("--diagram-"))
    XCTAssertTrue(portable.contains("rgba("))
    let repeated = await ResponseEngines.shared.diagram(source)
    XCTAssertEqual(svg, repeated)
    let ascii = await ResponseEngines.shared.diagramText(source)
    XCTAssertTrue(ascii?.contains("Receber") == true)
    let invalid = await ResponseEngines.shared.diagram("este não é um diagrama Mermaid")
    XCTAssertNil(invalid)
  }
}
