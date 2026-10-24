import Foundation
import Testing

@testable import OpenCodeKit

private let proseSource = """
  Primeiro parágrafo com **destaque**.

  ## Seção

  - Item um
  - Item dois

  > Uma citação.

  ---

  Depois da regra.

  ```swift
  let valor = 1
  ```

  Após o código.
  """

private func proseSections() throws -> (blocks: [MarkdownBlock], prose: MarkdownProse, tail: MarkdownProse) {
  let blocks = MarkdownBlocks.parse(proseSource)
  let sections = MarkdownBlocks.sections(blocks)
  #expect(sections.count == 3)
  guard case .prose(let prose) = sections[0], case .block(let code) = sections[1], case .prose(let tail) = sections[2]
  else { throw CancellationError() }
  #expect(code.kind == .code("swift"))
  return (blocks, prose, tail)
}

@Test func proseJoinsParagraphsHeadingsListsQuotationsAndRulesUntilCode() throws {
  let (_, prose, tail) = try proseSections()
  #expect(prose.segments.map(\.kind) == [.paragraph, .heading(2), .paragraph, .paragraph, .quote, .rule, .paragraph])
  #expect(prose.block.text == "Primeiro parágrafo com destaque.\nSeção\n•\tItem um\n•\tItem dois\nUma citação.\n \nDepois da regra.")
  #expect(prose.ranges.map { (prose.block.text as NSString).substring(with: $0) }
    == ["Primeiro parágrafo com destaque.", "Seção", "•\tItem um", "•\tItem dois", "Uma citação.", " ", "Depois da regra."])
  #expect(prose.spacing == [0, 20, 14, 10, 14, 14, 14])
  #expect(prose.id == prose.segments[0].id)
  #expect(tail.segments.map(\.kind) == [.paragraph])
  #expect(tail.spacing == [14])
}

@Test func proseCopiesMarkdownParagraphsAndOneListItemPerLine() throws {
  let (_, prose, _) = try proseSections()
  #expect(prose.block.copyText == "Primeiro parágrafo com destaque.\n\nSeção\n\n•\tItem um\n•\tItem dois\n\nUma citação.\n\n---\n\nDepois da regra.")
  let text = prose.block.text as NSString
  let start = text.range(of: "destaque").location
  let end = NSMaxRange(text.range(of: "Item um"))
  #expect(prose.block.copyText(in: NSRange(location: start, length: end - start)) == "destaque.\n\nSeção\n\n•\tItem um")
}

@Test func multiBlockSelectionQuotesTheExactSourceAndHighlightsEverySegment() throws {
  let (blocks, prose, _) = try proseSections()
  let text = prose.block.text as NSString
  let start = text.range(of: "destaque").location
  let end = NSMaxRange(text.range(of: "Item dois"))
  let quote = try #require(ChatQuote.selection(source: proseSource, block: prose.block,
    range: NSRange(location: start, length: end - start), messageID: "m", partID: "m:text:0"))
  let source = proseSource as NSString
  let sourceStart = source.range(of: "destaque").location
  let sourceEnd = NSMaxRange(source.range(of: "Item dois"))
  #expect(quote.anchor == .init(start: sourceStart, end: sourceEnd,
    exact: source.substring(with: NSRange(location: sourceStart, length: sourceEnd - sourceStart)), coordinate: "source"))
  #expect(quote.text == "destaque.\n\nSeção\n\n•\tItem um\n•\tItem dois")
  // The anchor resolves from the original blocks and maps back onto the joined text without separators or markers.
  let ranges = ChatQuoteAnchoring.sourceRanges(quote, source: proseSource, blocks: blocks)
  let rendered = ranges.flatMap { ConversationSearch.renderedRanges($0, block: prose.block) }
  #expect(rendered.map(text.substring) == ["destaque.", "Seção", "Item um", "Item dois"])
}

@Test func searchMatchesMapInsideTheirSegment() throws {
  let (_, prose, _) = try proseSections()
  let matches = ConversationSearch.ranges("item", in: proseSource)
  let rendered = matches.flatMap { ConversationSearch.renderedRanges($0, block: prose.block) }
  #expect(rendered.map((prose.block.text as NSString).substring) == ["Item", "Item"])
}

@Test func streamingKeepsEveryBlockApartUntilTheResponseCompletes() {
  let blocks = MarkdownBlocks.parse("Um.\n\nDois.\n\nTrês em andamento")
  #expect(MarkdownBlocks.sections(blocks).count == 1)
  let streaming = MarkdownBlocks.sections(blocks, streaming: true)
  #expect(streaming.map(\.id) == blocks.map(\.id))
  let spacing = streaming.compactMap { section -> Double? in
    if case .prose(let prose) = section, prose.segments.count == 1 { return prose.spacing[0] }
    return nil
  }
  #expect(spacing == [0, 14, 14])
  // The first block keeps its identity when the completed response joins it with the others.
  #expect(MarkdownBlocks.sections(blocks).first?.id == streaming.first?.id)
}

@Test func nonProseBlocksStaySeparate() {
  let blocks = MarkdownBlocks.parse("Texto.\n\n| A |\n| --- |\n| b |\n\n$$x^2$$\n\n![imagem](a.png)\n\nFim com nota[^clareza].\n\n[^clareza]: Nota explicativa.")
  let kinds = MarkdownBlocks.sections(blocks).map { section -> String in
    switch section {
    case .prose(let prose): "prose(\(prose.segments.count))"
    case .block(let block): "\(block.kind)"
    }
  }
  #expect(kinds.first == "prose(1)")
  #expect(kinds.contains("table") && kinds.contains("formula") && kinds.contains { $0.hasPrefix("image") })
  #expect(kinds.contains { $0.hasPrefix("footnote") })
}
