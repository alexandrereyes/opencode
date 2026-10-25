import Foundation
import Testing

@testable import OpenCodeKit

private let document = """
  # Guia de **leitura**

  Parágrafo com *ênfase*, `código` e um [link](https://example.com).

  - Primeiro item
  - [x] Tarefa feita
  - [ ] Tarefa pendente

  1. Passo um

  > Citação curta.

  ```swift
  let a = 1
  let b = 2
  ```

  | Nome | Valor |
  | --- | ---: |
  | A | 1 |
  | B | 2 |

  ![Diagrama do fluxo](fluxo.png)

  ---

  $$
  x^2
  $$

  Texto com nota[^1] e <b>HTML</b>.

  [^1]: Rodapé que não é lido.
  """

@Test func readAloudSpeaksProseAndAnnouncesEverythingElse() {
  let blocks = MarkdownBlocks.parse(document)
  let texts = ReadAloud.segments(blocks).map(\.text)
  #expect(texts == [
    "Guia de leitura.",
    "Parágrafo com ênfase, código e um link.",
    "Primeiro item.",
    "Concluído: Tarefa feita.",
    "Pendente: Tarefa pendente.",
    "Passo um.",
    "Citação curta.",
    "Bloco de código em swift, com 2 linhas.",
    "Tabela com 2 linhas, colunas Nome e Valor.",
    "Imagem: Diagrama do fluxo.",
    "Fórmula.",
    "Texto com nota e HTML.",
  ])
  // Every segment points at a top-level block that the viewer renders.
  #expect(ReadAloud.segments(blocks).allSatisfy { segment in blocks.contains { $0.id == segment.block } })
}

@Test func readAloudSkipsFrontMatterAndReadsDetails() {
  let source = "---\ntitle: Guia\n---\n\n<details><summary>Mais</summary>\n\nConteúdo escondido.\n\n</details>\n"
  let rendered = MarkdownDocument.renderable(source)
  let blocks = MarkdownBlocks.parse(rendered)
  #expect(ReadAloud.segments(blocks, frontMatter: rendered != source).map(\.text) == ["Mais.", "Conteúdo escondido."])
  #expect(ReadAloud.segments(blocks).first?.text == "Bloco de código em yaml, com 1 linha.")
}

@Test func readAloudPiecesStartShortAndCutAtSentenceEnds() {
  let sentence = "Esta frase tem exatamente um ponto final no fim dela. "
  let blocks = MarkdownBlocks.parse((1...40).map { "Parágrafo \($0). " + String(repeating: sentence, count: 3) }
    .joined(separator: "\n\n") + "\n\nVersão 3.14 do arquivo.md sem quebra.")
  let segments = ReadAloud.segments(blocks)
  let pieces = ReadAloud.pieces(segments)
  #expect(pieces.count > 4)
  #expect(pieces[0].text.count <= 220)
  #expect(pieces[1].text.count <= 650 && pieces[1].text.count > 220)
  #expect(pieces.dropFirst(2).dropLast().allSatisfy { $0.text.count <= 1_500 && $0.text.count > 1_000 })
  // Nothing is lost or reordered, and every cut falls after a sentence.
  let spoken = pieces.map(\.text).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
  #expect(spoken.replacingOccurrences(of: " ", with: "") == segments.map(\.text).joined().replacingOccurrences(of: " ", with: ""))
  #expect(pieces.dropLast().allSatisfy { $0.text.hasSuffix(".") })
  #expect(pieces.last?.text.hasSuffix("Versão 3.14 do arquivo.md sem quebra.") == true)
  // Each piece remembers the block its first words come from, in document order.
  #expect(pieces.map(\.block) == pieces.map(\.block).sorted())
  #expect(pieces[0].block == blocks[0].id)
}

@Test func readAloudSplitsOneLongSentenceAtASpace() {
  let words = Array(repeating: "palavra", count: 100).joined(separator: " ")
  let pieces = ReadAloud.pieces([.init(block: 7, text: words)], limits: [100])
  #expect(pieces.count == 9)
  #expect(pieces.allSatisfy { $0.text.count <= 100 && !$0.text.hasPrefix(" ") && $0.block == 7 })
  #expect(pieces.map(\.text).joined(separator: " ") == words)
}

@Test func readAloudTimelineEstimatesThenRefinesWithTheMeasuredRate() {
  let pieces = [200, 600, 1_200].map { ReadAloud.Piece(text: String(repeating: "a", count: $0), block: 0) }
  var timeline = ReadAloud.Timeline(pieces: pieces, charactersPerSecond: 10)
  #expect(timeline.total == 200)
  #expect(timeline.start(2) == 80)
  #expect(timeline.locate(0) == (piece: 0, fraction: 0))
  #expect(timeline.locate(50) == (piece: 1, fraction: 0.5))
  #expect(timeline.locate(500) == (piece: 2, fraction: 1))
  // The first piece took 25 s (8 per second): the rest moves most of the way there at once, not all of it.
  timeline.durations[0] = 25
  let blended = (ReadAloud.Timeline.priorCharacters + 200) / (ReadAloud.Timeline.priorCharacters / 10 + 25)
  #expect(abs(timeline.rate - blended) < 0.0001)
  #expect(timeline.rate > 8 && timeline.rate < 10)
  #expect(abs(timeline.duration(1) - 600 / blended) < 0.0001)
  #expect(timeline.time(piece: 1, offset: 999) == 25 + timeline.duration(1))
  // With most of the document measured the estimate is the document's own rate.
  timeline.durations[1] = 75
  let settled = (ReadAloud.Timeline.priorCharacters + 800) / (ReadAloud.Timeline.priorCharacters / 10 + 100)
  #expect(abs(timeline.rate - settled) < 0.0001)
  #expect(timeline.rate > 8 && timeline.rate < 9.1)
  #expect(abs(timeline.total - (100 + 1_200 / settled)) < 0.0001)
  #expect(ReadAloud.Timeline(pieces: [], charactersPerSecond: 12).locate(10) == (piece: 0, fraction: 0))
}

@Test func readAloudMapsPositionsToTextOffsets() {
  let pieces = ["Primeira frase. Segunda frase.", "Terceira frase aqui. Quarta.", "Quinta e última."]
    .map { ReadAloud.Piece(text: $0, block: 0) }
  #expect(ReadAloud.offset(pieces, piece: 0, fraction: 0) == 0)
  #expect(ReadAloud.offset(pieces, piece: 1, fraction: 0.5) == 30 + 14)
  #expect(ReadAloud.offset(pieces, piece: 9, fraction: 0) == 74)
  let location = ReadAloud.location(pieces, offset: 44)
  #expect(location.piece == 1 && abs(location.fraction - 0.5) < 0.0001)
  #expect(ReadAloud.location(pieces, offset: 0) == (piece: 0, fraction: 0))
  #expect(ReadAloud.location(pieces, offset: 500).piece == 2)
  #expect(ReadAloud.sentence(pieces, at: 20) == "Segunda frase.")
  #expect(ReadAloud.sentence(pieces, at: 31) == "Terceira frase aqui.")
  #expect(ReadAloud.hash(pieces) == ReadAloud.hash(pieces))
  #expect(ReadAloud.hash(pieces).count == 64)
  #expect(ReadAloud.hash(pieces) != ReadAloud.hash(Array(pieces.dropLast())))
}

@Test func readAloudAnchorsAReopenedDocumentAtItsSavedTime() {
  let pieces = [220, 650, 1_500].map { ReadAloud.Piece(text: String(repeating: "a", count: $0), block: 0) }
  var timeline = ReadAloud.Timeline(pieces: pieces, charactersPerSecond: 14)
  // Left 100 characters into the second piece after 16 s of audio: that pace fills in the first piece.
  let time = timeline.anchor(offset: 320, seconds: 16)
  #expect(abs(time - 16) < 0.0001)
  #expect(abs((timeline.durations[0] ?? 0) - 11) < 0.0001)
  #expect(timeline.durations[1] == nil)
  #expect(timeline.locate(time).piece == 1)
  // A place at the top anchors nothing.
  var fresh = ReadAloud.Timeline(pieces: pieces, charactersPerSecond: 14)
  #expect(fresh.anchor(offset: 0, seconds: 0) == 0)
  #expect(fresh.durations.allSatisfy { $0 == nil })
  let saved = ReadAloud.Bookmark(path: "/a.md", hash: "h", offset: 320, characters: 2_370, sentence: "", seconds: 16)
  #expect(try! JSONDecoder().decode(ReadAloud.Bookmark.self, from: JSONEncoder().encode(saved)) == saved)
}

@Test func readAloudResumesAfterEditsBySentenceOrFromTheStart() {
  let original = ["Introdução curta. Depois vem o meio do texto.", "Aqui está o trecho salvo. E segue."]
    .map { ReadAloud.Piece(text: $0, block: 0) }
  let offset = 45 + 3
  let bookmark = ReadAloud.Bookmark(path: "/docs/a.md", hash: ReadAloud.hash(original), offset: offset,
    characters: 79, sentence: ReadAloud.sentence(original, at: offset))
  #expect(bookmark.sentence == "Aqui está o trecho salvo.")
  // Same text: the exact place.
  #expect(ReadAloud.resume(bookmark, in: original) == offset)
  // A paragraph added before: the saved sentence, wherever it moved.
  let edited = [ReadAloud.Piece(text: "Novo parágrafo no começo. ", block: 0)] + original
  #expect(ReadAloud.resume(bookmark, in: edited) == 26 + 45)
  // The sentence was rewritten: the sentence start nearest to the old offset.
  let rewritten = ["Introdução curta. Depois vem o meio do texto.", "Outro texto no lugar. E segue."]
    .map { ReadAloud.Piece(text: $0, block: 0) }
  #expect(ReadAloud.resume(bookmark, in: rewritten) == 45)
  // The document got shorter than the saved place: from the beginning.
  #expect(ReadAloud.resume(bookmark, in: [ReadAloud.Piece(text: "Só isto.", block: 0)]) == nil)
}

@Test func readAloudFormatsClockAndCost() {
  #expect(ReadAloud.clock(0) == "0:00")
  #expect(ReadAloud.clock(252.9) == "4:12")
  #expect(ReadAloud.clock(3_725) == "1:02:05")
  #expect(abs(ReadAloud.cost(seconds: ReadAloud.confirmationSeconds, usdPerSecond: 0.00015) - 0.27) < 0.0001)
}
