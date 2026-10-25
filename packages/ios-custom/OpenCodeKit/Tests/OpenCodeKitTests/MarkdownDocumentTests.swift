import Foundation
import Testing

@testable import OpenCodeKit

@Test func markdownDocumentSlicesBlocksInOrderWithBoundedSizeAndSpacing() {
  let source = (1...60).map { "## Seção \($0)\n\n" + String(repeating: "Texto do parágrafo \($0). ", count: 12) }
    .joined(separator: "\n\n") + "\n\n```swift\nlet fim = true\n```\n"
  let blocks = MarkdownBlocks.parse(source)
  let chunks = MarkdownDocument.chunks(blocks)
  #expect(chunks.flatMap(\.blocks) == blocks)
  #expect(chunks.count > 5)
  #expect(chunks.allSatisfy { $0.blocks.count <= 12 })
  #expect(chunks.dropFirst().allSatisfy { chunk in
    chunk.blocks.count == 1 || chunk.blocks.reduce(0) { $0 + $1.text.utf16.count } <= 1_500
  })
  #expect(chunks.first?.spacing == 0)
  // Each slice keeps the spacing its first block had after the previous slice's last block.
  for (previous, chunk) in zip(chunks, chunks.dropFirst()) {
    #expect(chunk.spacing == MarkdownBlocks.spacing(chunk.blocks[0], after: previous.blocks.last))
  }
  #expect(Set(chunks.map(\.id)).count == chunks.count)
  #expect(MarkdownDocument.chunks([]).isEmpty)
}

@Test func markdownDocumentFlagsOnlyBlocksTooTallForOneTextView() {
  #expect(!MarkdownDocument.oversized(MarkdownBlocks.parse("# Título\n\nTexto curto.")))
  let listing = "```\n" + Array(repeating: "linha de log com algum conteúdo", count: 2_000).joined(separator: "\n") + "\n```"
  #expect(MarkdownDocument.oversized(MarkdownBlocks.parse(listing)))
}

@Test func markdownDocumentShowsFrontMatterAsYamlCode() {
  let rendered = MarkdownDocument.renderable("---\ntitle: Guia\ntags: [ios]\n---\n\n# Guia\n")
  #expect(rendered == "```yaml\ntitle: Guia\ntags: [ios]\n```\n\n# Guia\n")
  let blocks = MarkdownBlocks.parse(rendered)
  #expect(blocks.first?.kind == .code("yaml"))
  #expect(MarkdownDocument.renderable("# Sem metadados\n\n---\n\nFim") == "# Sem metadados\n\n---\n\nFim")
  #expect(MarkdownDocument.renderable("---\nsem fechamento") == "---\nsem fechamento")
  #expect(MarkdownDocument.renderable("---\na: \"```\"\n---\nx").hasPrefix("````yaml\n"))
}

@Test func markdownDocumentLinksResolveAgainstTheFileDirectory() {
  let file = "/repo/docs/guia.md"
  #expect(MarkdownDocument.linkedFile("outro.md", from: file) == "/repo/docs/outro.md")
  #expect(MarkdownDocument.linkedFile("../README.md#L3", from: file) == "/repo/README.md")
  #expect(MarkdownDocument.linkedFile("./img/a.png", from: file) == "/repo/docs/img/a.png")
  #expect(MarkdownDocument.linkedFile("/tmp/x.md", from: file) == "/tmp/x.md")
  #expect(MarkdownDocument.linkedFile("~/notas.md", from: file) == "~/notas.md")
  #expect(MarkdownDocument.linkedFile("#secao", from: file) == nil)
  #expect(MarkdownDocument.linkedFile("https://example.com", from: file) == nil)
}
