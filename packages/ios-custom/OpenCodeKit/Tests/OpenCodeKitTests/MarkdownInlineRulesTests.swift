import Foundation
import Testing
@testable import OpenCodeKit

private func formulas(_ source: String) -> [MarkdownFormula] {
  func all(_ blocks: [MarkdownBlock]) -> [MarkdownFormula] {
    blocks.flatMap { block in
      block.runs.compactMap(\.formula) + (block.table?.rows.flatMap { $0.flatMap { $0.compactMap(\.formula) } } ?? [])
        + all(block.children)
    }
  }
  return all(MarkdownBlocks.parse(source))
}

@Test(arguments: [
  "R$ 30.982,69 e US$ 1.200,00",
  "Custa R$30 ou R$40.",
  "Moedas R$x e US$.",
  #"Escapado \$x$ e \$HOME"#,
  "Entre $5 e $10.",
  "It costs $5, originally $10, ranging from $1,000 to $2,000.",
  "paid $5/$6.",
  "Use $HOME/$USER or $PATH:$HOME",
  "$ x $ tem espaço nos delimitadores",
  "$x$5 fecha antes de dígito",
  "$a\nb$ atravessa a linha",
])
func dollarMathKeepsPricesAndVariablesAsText(_ source: String) {
  #expect(formulas(source).isEmpty, "\(source)")
}

@Test(arguments: [
  ("$x$", "x"),
  ("Energia $E = mc^2$.", "E = mc^2"),
  ("因此$x^2$是正数", "x^2"),
  ("o eixo $x$-horizontal", "x"),
  ("($x$)", "x"),
  (#"Escapado $a\$b$ dentro"#, #"a\$b"#),
])
func dollarMathRendersFormulas(_ sample: (String, String)) {
  #expect(formulas(sample.0).map(\.source) == [sample.1])
  #expect(formulas(sample.0).allSatisfy { !$0.display })
}

@Test func dollarMathKeepsEveryFormulaOfALineAndDisplayMath() {
  #expect(formulas("$a_1$ e $b_1$.").map(\.source) == ["a_1", "b_1"])
  let display = formulas("$$\n\\bar{x} = \\frac{1}{n}\n$$")
  #expect(display.map(\.source) == [#"\bar{x} = \frac{1}{n}"#] && display[0].display)
}

@Test func tableCurrencyStaysTextAndStrongWithinItsCell() throws {
  let source = """
  | Cenário | Valor | Resultado |
  |:---|---:|---:|
  | A | R$ 24.310,55 | **Prejuízo de R$ 19.875,42** |
  | B | $5 | $10 |
  """
  let block = try #require(MarkdownBlocks.parse(source).first)
  let table = try #require(block.table)
  #expect(table.alignments == [.leading, .trailing, .trailing])
  #expect(table.rows.count == 3 && table.rows.allSatisfy { $0.count == 3 })
  #expect(table.rows.allSatisfy { $0.allSatisfy { $0.allSatisfy { $0.formula == nil } } })
  #expect(table.rows[1][1].map(\.text).joined() == "R$ 24.310,55")
  #expect(table.rows[1][2].allSatisfy { $0.strong } && table.rows[1][2].map(\.text).joined() == "Prejuízo de R$ 19.875,42")
}

@Test func tableFormulaNeverCrossesCellsAndDisplayStaysInline() throws {
  #expect(formulas("| a | b |\n|---|---|\n| $x | y$ |").isEmpty)
  let source = "| a | b |\n|---|---|\n| $x^2$ | $$y$$ |"
  let blocks = MarkdownBlocks.parse(source)
  #expect(blocks.count == 1 && blocks[0].kind == .table)
  let row = try #require(blocks[0].table?.rows.last)
  #expect(row[0].compactMap(\.formula).map(\.source) == ["x^2"])
  #expect(row[1].compactMap(\.formula).map { "\($0.source) \($0.display)" } == ["y false"])
}

@Test func inlineHTMLTagsStyleTheirContentWithoutShowingTags() throws {
  let source = "<sub>Fontes: GET `/carteira` e [PTAX](https://example.com/ptax).</sub>"
  let note = try #require(MarkdownBlocks.parse(source).first)
  #expect(note.text == "Fontes: GET /carteira e PTAX.")
  #expect(note.runs.allSatisfy { $0.small })
  #expect(note.runs.contains { $0.code && $0.text == "/carteira" })
  #expect(note.runs.contains { $0.link == "https://example.com/ptax" && $0.text == "PTAX" })
  let range = try #require(note.sourceRange(for: (note.text as NSString).range(of: "Fontes")))
  #expect((source as NSString).substring(with: range) == "Fontes")

  let styled = try #require(MarkdownBlocks.parse(
    "x<sup>2</sup> <b>b</b> <strong>s</strong> <i>i</i> <em>e</em> <u>u</u> <s>r</s> <del>d</del> <code>c</code> <kbd>K</kbd> <small>p</small> a<br>b<br/>c<BR />d").first)
  #expect(styled.text == "x2 b s i e u r d c K p a\nb\nc\nd")
  func run(_ text: String) -> MarkdownRun? { styled.runs.first { $0.text == text } }
  #expect(run("2")?.superscript == true && run("2")?.link == nil)
  #expect(run("b")?.strong == true && run("s")?.strong == true)
  #expect(run("i")?.emphasis == true && run("e")?.emphasis == true)
  #expect(run("u")?.underline == true)
  #expect(run("r")?.strikethrough == true && run("d")?.strikethrough == true)
  #expect(run("c")?.code == true && run("K")?.code == true)
  #expect(run("p")?.small == true)
  #expect(styled.runs.filter { $0.text == "\n" }.allSatisfy { $0.offsets.allSatisfy { $0 != nil } })
}

@Test func unknownOrUnclosedInlineHTMLStaysLiteral() throws {
  #expect(MarkdownBlocks.parse("<span>x</span> e <sub>aberto").first?.text == "<span>x</span> e <sub>aberto")
  #expect(MarkdownBlocks.parse("**<sub>a** b</sub>").first?.text == "<sub>a b</sub>")
  let nested = try #require(MarkdownBlocks.parse("<b>a <b>b</b> c</b>").first)
  #expect(nested.text == "a b c" && nested.runs.allSatisfy { $0.strong })
}

@Test func readAloudSkipsTagsAndKeepsPricesAndSuperscripts() throws {
  let blocks = MarkdownBlocks.parse("<sub>Fontes: GET `/carteira`.</sub>\n\nCusta R$ 5,00 ou US$ 3, x<sup>2</sup> e linha<br>nova.")
  #expect(ReadAloud.prose(blocks[0]) == "Fontes: GET /carteira.")
  #expect(ReadAloud.prose(blocks[1]) == "Custa R$ 5,00 ou US$ 3, x2 e linha\nnova.")
  let notes = MarkdownBlocks.parse("Texto[^a].\n\n[^a]: Uma nota explicativa.")
  #expect(ReadAloud.prose(notes[0]) == "Texto.")
}

@Test func tableColumnsShareSpaceWithoutBreakingWords() {
  // Everything fits: natural widths plus an equal share of the rest.
  #expect(MarkdownTable.columnWidths(natural: [100, 120], minimum: [60, 80], available: 260, wrap: true) == [120, 140])
  // Narrow columns keep their natural width; the others share an equal level above their longest word.
  let shared = MarkdownTable.columnWidths(natural: [120, 400, 500], minimum: [100, 90, 150], available: 500, wrap: true)
  #expect(abs(shared.reduce(0, +) - 500) < 0.01)
  #expect(abs(shared[0] - 120) < 0.01 && abs(shared[1] - 190) < 0.01 && abs(shared[2] - 190) < 0.01)
  // A column whose longest word exceeds the level keeps that minimum.
  let floored = MarkdownTable.columnWidths(natural: [400, 400], minimum: [100, 260], available: 400, wrap: true)
  #expect(abs(floored[1] - 260) < 0.01 && abs(floored[0] - 140) < 0.01)
  // Minimums wider than the screen: the table scrolls instead of breaking words.
  #expect(MarkdownTable.columnWidths(natural: [300, 300, 300], minimum: [140, 150, 160], available: 400, wrap: true) == [140, 150, 160])
  // Without wrapping every column keeps its single-line width.
  #expect(MarkdownTable.columnWidths(natural: [300, 300], minimum: [100, 100], available: 400, wrap: false) == [300, 300])
}
