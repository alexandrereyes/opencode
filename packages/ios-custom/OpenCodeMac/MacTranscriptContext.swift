import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// What the transcript's cells need from the chat column, like the iPhone's `TranscriptContext`. Hosted cells
/// live in AppKit, outside the column's SwiftUI tree, so they read it here; it is observable, so a cell re-renders
/// only for the values it read.
@MainActor @Observable final class MacTranscriptContext {
  let store: ConversationStore
  let client: OpenCodeClient
  var theme = AppTheme.selected
  /// Space on each side of the content column: the transcript reads at most 760 points wide, centered.
  var inset: CGFloat = 24
  /// The transcript's width.
  var width: CGFloat = 808
  var quotes = ConversationQuoteContext()
  var search = ConversationSearchHighlight()
  /// The transcript's viewport; prompts cap their text at 40% of its height, like the iPhone.
  var viewport: CGFloat = 800
  var rasterRevision = 0
  /// Prompts whose bubble is pinned at the top right now.
  var pinned: String?
  @ObservationIgnored var openChild: (String) -> Void = { _ in }
  @ObservationIgnored var openPath: (String) -> Void = { _ in }
  @ObservationIgnored var loadOlder: () -> Void = {}
  @ObservationIgnored var revealTurn: (String) -> Bool = { _ in false }
  @ObservationIgnored var revert: (ConversationMessage) -> Void = { _ in }
  @ObservationIgnored var comment: (ChatQuote) -> Void = { _ in }
  @ObservationIgnored var openImage: (CGImage, String) -> Void = { _, _ in }
  @ObservationIgnored var scrollKey: (NSEvent) -> Bool = { _ in false }
  @ObservationIgnored var blockLookup: (TranscriptPart) -> [MarkdownBlock]? = { _ in nil }
  @ObservationIgnored var rasterLookup: (String) -> [ResponseFormulaKey: ResponseFormulaRaster] = { _ in [:] }

  init(store: ConversationStore, client: OpenCodeClient) {
    self.store = store
    self.client = client
  }

  /// Where conversation images load from: the server and the session's directory.
  var images: (client: OpenCodeClient, directory: String)? {
    store.session.map { (client, $0.location.directory) }
  }

  func rasters(_ part: TranscriptPart) -> [ResponseFormulaKey: ResponseFormulaRaster] {
    _ = rasterRevision
    return rasterLookup(part.partID)
  }

  /// A link in an answer: a file opens Arquivos at its folder; anything else opens in its app.
  func open(_ url: URL) {
    if let path = FileReference.path(url) {
      openPath(path)
      return
    }
    NSWorkspace.shared.open(url)
  }

  /// Quote marks inside one text part, anchored to its source against the whole part's blocks.
  func responseQuotes(_ part: TranscriptPart) -> [ResponseQuoteHighlight] {
    let marks = quotes.index.marks(messageID: part.messageID, partID: part.partID, pending: quotes.pending,
      dismissed: quotes.dismissed, revealing: quotes.revealing)
    let blocks = marks.isEmpty ? [] : blockLookup(part) ?? []
    return marks.compactMap { mark in
      let ranges = ChatQuoteAnchoring.sourceRanges(mark.quote, source: part.source, blocks: blocks)
      return ranges.isEmpty ? nil : ResponseQuoteHighlight(mark: mark, ranges: ranges,
        badge: mark.pending || !quotes.dismissed.contains(mark.quote.id))
    }
  }
}
