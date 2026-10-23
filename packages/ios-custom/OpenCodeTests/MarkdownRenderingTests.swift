import OpenCodeKit
import UIKit
import XCTest
@testable import OpenCode

@MainActor final class MarkdownRenderingTests: XCTestCase {
  func testListStrongPrefixDoesNotChangeRegularBodyOrMarkers() throws {
    let source = """
    Os três ajustes:

    1. **Testes sem depender da ordem.** Cada cenário prepara seus próprios dados.
       1. **Cenário aninhado.** O restante fica regular com `código em linha`.
    2. Item totalmente regular.

    - **Marcador forte.** Continuação regular.
    - [x] **Tarefa forte.** Continuação regular.
    """
    for theme in ["openchamber-dark", "openchamber-light"] {
      for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        for block in MarkdownBlocks.parse(source) {
          let text = ResponseTextStyle.text(block, theme: AppTheme.load(theme), traits: traits)
          var offset = 0
          for run in block.runs {
            let font = AppTypography.font(run.code ? .secondary : .body,
              weight: run.strong ? .semibold : .regular, monospaced: run.code, compatibleWith: traits)
            for index in offset..<(offset + run.text.utf16.count) {
              let actual = try XCTUnwrap(text.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
              // Markers use monospaced digits, but never inherit a following strong span.
              XCTAssertEqual(weight(actual), weight(font), "\(theme) \(category): \(run.text)")
              XCTAssertEqual(actual.pointSize, font.pointSize)
            }
            offset += run.text.utf16.count
          }
        }
      }
    }
  }

  func testHeadingWeightsMatchOpenChamberWithoutChangingScale() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      for level in 1...6 {
        let block = try XCTUnwrap(MarkdownBlocks.parse(String(repeating: "#", count: level) + " Título **forte** e *itálico*").first)
        let text = ResponseTextStyle.text(block, theme: AppTheme.load(theme))
        let style: AppTextStyle = [.title, .heading, .message, .secondary, .secondary, .secondary][level - 1]
        let expected = AppTypography.font(style, weight: .semibold)
        for index in 0..<text.length {
          let actual = try XCTUnwrap(text.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
          XCTAssertEqual(weight(actual), weight(expected), "h\(level)")
          XCTAssertEqual(actual.pointSize, expected.pointSize)
        }
      }
    }
  }

  func testParagraphQuoteAndTableWeightsKeepStrongScoped() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      for source in ["**Prefixo.** Continuação regular.", "> **Prefixo.** Continuação regular."] {
        let block = try XCTUnwrap(MarkdownBlocks.parse(source).first)
        let text = ResponseTextStyle.text(block, theme: AppTheme.load(theme))
        for token in ["Prefixo.", "Continuação regular."] {
          let range = (text.string as NSString).range(of: token)
          XCTAssertNotEqual(range.location, NSNotFound)
          let font = try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
          XCTAssertEqual(weight(font), weight(AppTypography.font(.body, weight: token == "Prefixo." ? .semibold : .regular)))
        }
      }
      let block = try XCTUnwrap(MarkdownBlocks.parse("| Cabeçalho |\n| --- |\n| **Forte** regular |\n").first)
      let table = try XCTUnwrap(block.table)
      for (row, cells) in table.rows.enumerated() {
        let cell = block.cell(try XCTUnwrap(cells.first), alignment: .leading)
        let text = ResponseTextStyle.text(cell, theme: AppTheme.load(theme), tableHeader: row == 0)
        var offset = 0
        for run in cell.runs {
          let actual = try XCTUnwrap(text.attribute(.font, at: offset, effectiveRange: nil) as? UIFont)
          XCTAssertEqual(weight(actual), weight(AppTypography.font(.secondary, weight: row == 0 || run.strong ? .semibold : .regular)))
          offset += run.text.utf16.count
        }
      }
    }
  }

  private func weight(_ font: UIFont) -> Double {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
  }

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
