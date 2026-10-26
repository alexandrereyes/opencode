import Foundation
import Testing
@testable import OpenCodeKit

@Test func markdownParityPreservesStylesBreaksAndInlineHTML() throws {
  let blocks = MarkdownBlocks.parse("**forte** *leve* ~~antigo~~ **`nome`**\nlinha suave  \nlinha explícita\n\n<kbd>⌘</kbd> <span>x</span>")
  let first = try #require(blocks.first)
  #expect(first.runs.contains { $0.strikethrough && $0.text == "antigo" })
  #expect(first.runs.contains { $0.code && $0.strong && $0.text == "nome" })
  #expect(first.text.contains("nome linha suave\nlinha explícita"))
  #expect(blocks.last?.runs.contains { $0.code && $0.text == "⌘" } == true)
  #expect(blocks.last?.text == "⌘ <span>x</span>")
}

@Test func markdownParityProjectsTableCellsAlignmentAndExports() throws {
  let source = "| Nome | Centro | Valor |\n| :--- | :---: | ---: |\n| **ação** | a\\|b | 12,50 |\n| linha | `x` | \"sim\" |"
  let block = try #require(MarkdownBlocks.parse(source).first)
  let table = try #require(block.table)
  #expect(table.alignments == [.leading, .center, .trailing])
  #expect(table.rows.count == 3)
  #expect(table.rows[1][0].contains { $0.strong })
  #expect(table.rows[1][1].map(\.text).joined() == "a|b")
  #expect(table.markdown == source)
  #expect(table.delimited(",").contains("\"12,50\""))
  #expect(table.delimited(",").contains("\"\"\"sim\"\"\""))
  #expect(table.delimited("\t").contains("ação\ta|b\t12,50"))
  let cell = block.cell(table.rows[1][0])
  let range = try #require(cell.sourceRange(for: NSRange(location: 0, length: cell.text.utf16.count)))
  #expect((source as NSString).substring(with: range) == "ação")
}

@Test func markdownParityKeepsTaskStateHangingIndentAndNestedQuotes() {
  let blocks = MarkdownBlocks.parse("- [x] Pronto\n- [ ] Depois\n  - Filho\n\n> Um\n>\n> > Dois")
  #expect(blocks[0].marker?.checked == true)
  #expect(blocks[1].marker?.checked == false)
  #expect(blocks[2].text.hasPrefix("◦\t"))
  #expect(blocks[2].indent == 20)
  #expect(blocks[0].marker?.width == 20)
  #expect(blocks.last?.quoteDepth == 2)
  #expect(blocks.dropLast().last?.quoteDepth == 1)
  #expect(MarkdownListMarkers.ordered(7, depth: 0) == "7.")
  #expect(MarkdownListMarkers.ordered(27, depth: 1) == "aa.")
  #expect(MarkdownListMarkers.ordered(14, depth: 2) == "xiv.")
}

@Test(arguments: [
  ("$E = mc^2$", "E = mc^2", false),
  (#"\(a^2 + b^2\)"#, "a^2 + b^2", false),
  ("$$\n\\frac{1}{3}\n$$", #"\frac{1}{3}"#, true),
  (#"\["# + "\n" + #"\int_0^1 x\,dx"# + "\n" + #"\]"#, #"\int_0^1 x\,dx"#, true),
])
func markdownParityDetectsMathAndMapsAttachmentSelection(_ sample: (String, String, Bool)) throws {
  let block = try #require(MarkdownBlocks.parse(sample.0).first)
  let formula = try #require(block.runs.first?.formula)
  #expect(formula.source == sample.1 && formula.display == sample.2)
  #expect(block.text == "\u{fffc}")
  let selection = try #require(block.sourceRange(for: NSRange(location: 0, length: 1)))
  #expect((sample.0 as NSString).substring(with: selection) == sample.0)
}

@Test func markdownParityMathSkipsCurrencyCodeAndEscapes() {
  let source = #"Moeda $100$, $5 e $10, \$x\$; `$E=mc^2$`; código abaixo."# + "\n\n```tex\n$x^2$\n```"
  #expect(MarkdownBlocks.parse(source).allSatisfy { $0.runs.allSatisfy { $0.formula == nil } })
  let mixed = MarkdownBlocks.parse("Antes **$x^2$** e depois 😀.").first!
  #expect(mixed.runs.contains { $0.formula?.source == "x^2" && $0.strong })
  let sourceRange = mixed.sourceRange(for: (mixed.text as NSString).range(of: "depois 😀"))!
  #expect(("Antes **$x^2$** e depois 😀." as NSString).substring(with: sourceRange) == "depois 😀")
  let query = ("Antes **$x^2$** e depois 😀." as NSString).range(of: "x^2")
  #expect(ConversationSearch.renderedRanges(query, block: mixed) == [(mixed.text as NSString).range(of: "\u{fffc}")])
}

@Test func markdownParityFootnotesNumberReuseDedentAndSourceOffsets() throws {
  let source = "Uma nota[^b], outra[^a] e a mesma[^b].\n\n[^a]: Texto simples.\n[^b]: **café 😀**\n\n    Segundo parágrafo com `código`."
  let blocks = MarkdownBlocks.parse(source)
  let references = blocks.first!.runs.filter(\.superscript)
  #expect(references.map(\.text) == ["1", "2", "1"])
  let note = try #require(blocks.first { $0.kind == .footnote("b", 1) })
  #expect(note.children.count == 2)
  let text = note.children[0]
  let range = try #require(text.sourceRange(for: (text.text as NSString).range(of: "café 😀")))
  #expect((source as NSString).substring(with: range) == "café 😀")
  #expect(note.children[1].runs.contains { $0.code && $0.text == "código" })
}

@Test func markdownParityDetailsPreservesNestedMarkdownAndLiteralCode() throws {
  let source = "Antes\n\n<details open>\n<summary>**Revisão**</summary>\n\nTexto com `código`.\n\n<details>\n<summary>Filho</summary>\n\nConteúdo interno.\n\n</details>\n\n</details>\n\n```html\n<details>não abrir</details>\n```"
  let blocks = MarkdownBlocks.parse(source)
  let details = try #require(blocks.first { if case .details = $0.kind { true } else { false } })
  #expect(details.kind == .details("**Revisão**", true))
  #expect(details.runs.first?.strong == true)
  #expect(details.children.contains { $0.runs.contains { $0.code && $0.text == "código" } })
  #expect(details.children.contains { $0.kind == .details("Filho", false) })
  #expect(blocks.last?.kind == .code("html"))
  let first = MarkdownBlocks.parse("<details>\n<summary>Resumo</summary>\n\nPrimeiro.\n\n</details>")[0]
  let grown = MarkdownBlocks.parse("<details>\n<summary>Resumo</summary>\n\nPrimeiro.\n\nSegundo.\n\n</details>")[0]
  #expect(first.id == grown.id)
}

@Test func markdownParityLanguageAndSyntaxMappingsAreSemantic() {
  #expect(MarkdownCodeProjection.language("C++ file.cpp") == "cpp")
  #expect(MarkdownCodeProjection.language("ZSH") == "bash")
  #expect(MarkdownCodeProjection.language("text") == nil)
  #expect(MarkdownCodeProjection.language("linguagem-inexistente") == "linguagem-inexistente")
  #expect(MarkdownCodeProjection.syntax("hljs-title function_") == .function)
  #expect(MarkdownCodeProjection.syntax("hljs-comment hljs-doctag") == .comment)
  #expect(MarkdownCodeProjection.syntax("hljs-attr") == .property)
  #expect(MarkdownCodeProjection.syntax("hljs-number") == .number)
  #expect(MarkdownCodeProjection.syntax("hljs-section") == .type)
  #expect(MarkdownCodeProjection.syntax("hljs-code") == .string)
  #expect(MarkdownCodeProjection.syntax("") == nil)
  let code = MarkdownBlocks.parse("```js\nconst x = 1;\n```")[0]
  #expect(code.text == "const x = 1;\n")
  #expect(code.codeDisplay.text == "const x = 1;")
  #expect(code.codeDisplay.runs.flatMap(\.offsets).count == code.codeDisplay.text.utf16.count)
}

@Test func markdownParityMathDoesNotCrossLinksAndSupportsQuotedDisplayCRLF() throws {
  let linked = MarkdownBlocks.parse(#"\$x$ and [https://example.test/$x$](https://example.test/$x$)"#)
  #expect(linked.allSatisfy { $0.runs.allSatisfy { $0.formula == nil } })
  let currency = MarkdownBlocks.parse("$5 [item](https://example.test/$x$) $10")
  #expect(currency.allSatisfy { $0.runs.allSatisfy { $0.formula == nil } })
  let quoted = MarkdownBlocks.parse("> Uma nota\r\n> \\[\r\n> x+y\r\n> \\]")
  let formula = try #require(quoted.first { $0.kind == .formula })
  #expect(formula.quoteDepth == 1)
  #expect(formula.runs.first?.formula?.source == "x+y")
}

@Test func markdownParityGfmAutolinksRetainOffsetsAndSkipCodeAndBareFilenames() throws {
  let source = "Abra https://www.markdownguide.org e www.example.com. E-mail pessoa@example.com. README.md não é um link. `https://code.example.com`"
  let block = try #require(MarkdownBlocks.parse(source).first)
  let links = block.runs.filter { $0.link != nil }
  #expect(links.count == 3)
  #expect(links.contains { $0.text == "www.example.com" && $0.link?.hasPrefix("http") == true })
  #expect(links.contains { $0.link == "mailto:pessoa@example.com" })
  #expect(!links.contains { $0.text.contains("README") || $0.text.contains("code.example") })
  let range = try #require(block.sourceRange(for: (block.text as NSString).range(of: "www.example.com")))
  #expect((source as NSString).substring(with: range) == "www.example.com")
  let mathUrl = MarkdownBlocks.parse("https://example.com/$x$ e $y^2$")[0]
  #expect(mathUrl.runs.filter { $0.formula != nil }.count == 1)
}
