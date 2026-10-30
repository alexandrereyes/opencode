import Observation
import OpenCodeKit
import SwiftUI

/// The conversation environment that transcript cells need. Hosted cells live in UIKit, outside the SwiftUI
/// tree that defines these values, so the conversation copies them here and every cell applies them again.
/// It is observable: a cell re-renders only for the values it actually read.
@MainActor @Observable final class TranscriptContext {
  let store: ConversationStore
  var theme = AppTheme.selected
  var quotes = ConversationQuoteContext()
  var search = ConversationSearchHighlight()
  var selection: ResponseSelectionActions?
  var selectionChanged: ResponseSelectionObserver?
  var images: ConversationImageContext?
  var openFile: FileOpenAction?
  var openImage: ImageOpenAction?
  var revert: UserMessageRevertAction?
  var promptJump: UserPromptJump?
  /// The conversation's size; prompts cap their text at 40% of its height, like the pinned header always did.
  var size = CGSize(width: 440, height: 800)
  /// Bumped when formula images land, which change no geometry and no item.
  var rasterRevision = 0
  @ObservationIgnored var openChild: (String) -> Void = { _ in }
  @ObservationIgnored var openNote: (TranscriptPart, String) -> Void = { _, _ in }
  @ObservationIgnored var loadOlder: () -> Void = {}
  @ObservationIgnored var blockLookup: (TranscriptPart) -> [MarkdownBlock]? = { _ in nil }
  @ObservationIgnored var rasterLookup: (String) -> [ResponseFormulaKey: ResponseFormulaRaster] = { _ in [:] }

  init(store: ConversationStore) {
    self.store = store
  }

  func rasters(_ part: TranscriptPart) -> [ResponseFormulaKey: ResponseFormulaRaster] {
    _ = rasterRevision
    return rasterLookup(part.partID)
  }

  /// Quote marks inside one text part, anchored to its source against the whole part's blocks.
  func responseQuotes(_ part: TranscriptPart) -> ResponseQuoteContext {
    let marks = quotes.index.marks(messageID: part.messageID, partID: part.partID, pending: quotes.pending,
      dismissed: quotes.dismissed, revealing: quotes.revealing)
    let blocks = marks.isEmpty ? [] : blockLookup(part) ?? []
    let highlights = marks.compactMap { mark -> ResponseQuoteHighlight? in
      let ranges = ChatQuoteAnchoring.sourceRanges(mark.quote, source: part.source, blocks: blocks)
      // A revealed dismissed mark only draws its background: no marker reflows the text.
      return ranges.isEmpty ? nil : ResponseQuoteHighlight(mark: mark, ranges: ranges,
        badge: mark.pending || !quotes.dismissed.contains(mark.quote.id))
    }
    return ResponseQuoteContext(highlights: highlights, open: quotes.open, target: quotes.target,
      active: quotes.active, align: quotes.align)
  }
}

/// Re-applies the conversation environment inside a hosted cell.
struct TranscriptEnvironment: ViewModifier {
  let context: TranscriptContext
  func body(content: Content) -> some View {
    content
      .environment(\.appTheme, context.theme)
      .environment(context.store.toast)
      .environment(\.transcriptMemory, context.store.memory)
      .environment(\.conversationQuotes, context.quotes)
      .environment(\.conversationSearch, context.search)
      .environment(\.responseSelection, context.selection)
      .environment(\.responseSelectionChanged, context.selectionChanged)
      .environment(\.conversationImages, context.images)
      .environment(\.openFile, context.openFile)
      .environment(\.openImage, context.openImage)
      .environment(\.userMessageRevert, context.revert)
      .environment(\.userPromptJump, context.promptJump)
      .environment(\.userMessageSnippet, UserMessageSnippetAction { [store = context.store] text in
        store.snippetEditor = SnippetEditorLaunch(content: text)
      })
      .environment(\.locale, Locale(identifier: "pt_BR"))
  }
}
