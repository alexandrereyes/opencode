import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// The avatar Sessões shows for the session, beside the user's prompts (`SessionAvatar`'s choice): the shared chat
/// avatar, the project's own icon or its monogram on its color; the Sessão mestra's symbol for the master; and the
/// OpenCode glyph when there is nothing else.
struct MacTranscriptAvatar: Equatable {
  enum Kind: Equatable { case chats, icon(ProjectIcon), monogram, master, opencode }
  let kind: Kind
  let color: String
  let monogram: String

  init(_ row: SessionRow?, mixChats: Bool, master: Bool) {
    let monogram = row.map { SessionList.monogram($0.projectName) } ?? ""
    self.monogram = monogram
    color = row.map { SessionList.avatarColor($0.project, fallback: $0.session.projectID) } ?? ""
    kind = if master { .master }
      else if let row, row.sharesChatAvatar(mixed: mixChats) { .chats }
      else if let row, !row.chat, let icon = ProjectIcon.of(row.project) { .icon(icon) }
      else if !monogram.isEmpty { .monogram }
      else { .opencode }
  }
}

/// What the transcript's cells need from the chat column, like the iPhone's `TranscriptContext`. Hosted cells
/// live in AppKit, outside the column's SwiftUI tree, so they read it here; it is observable, so a cell re-renders
/// only for the values it read.
@MainActor @Observable final class MacTranscriptContext {
  let store: ConversationStore
  let memory: TranscriptMemory
  let client: OpenCodeClient
  var theme = AppTheme.selected
  /// The reading column, icons included: at most 960 pt, centered, with at least 28 pt on each side. That keeps an
  /// answer's lines under about 125 characters at 14 pt (past that the eye loses the next line), while a large
  /// window still gives the chat far more than the old 760 pt.
  static let column: CGFloat = 960
  static let minimumInset: CGFloat = 28
  /// The icons beside the messages (28 pt, as in the approved mock) and their 10-pt gap: the answer's text starts
  /// after it, the prompt's bubble ends before it.
  static let gutter: CGFloat = 38
  static let icon: CGFloat = 28
  /// Space on each side of the content column.
  var inset: CGFloat = 28
  /// The transcript's width.
  var width: CGFloat = 808
  /// The first item of each answer (after its prompt), which shows the OpenCode icon at its top left.
  var responseStarts: Set<String> = []
  /// The session's project, shown beside the prompts like its avatar in Sessões.
  var avatar: MacTranscriptAvatar?
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
  /// Pergunta paralela about a selected passage (its source text).
  @ObservationIgnored var sideQuestion: (String) -> Void = { _ in }
  @ObservationIgnored var readAloud: (String) -> Void = { _ in }
  /// The image shown, its name and its source (to read the original).
  @ObservationIgnored var openImage: (CGImage, String, String) -> Void = { _, _, _ in }
  @ObservationIgnored var scrollKey: (NSEvent) -> Bool = { _ in false }
  @ObservationIgnored var blockLookup: (TranscriptPart) -> [MarkdownBlock]? = { _ in nil }
  @ObservationIgnored var rasterLookup: (String) -> [ResponseFormulaKey: ResponseFormulaRaster] = { _ in [:] }

  init(store: ConversationStore, memory: TranscriptMemory, client: OpenCodeClient) {
    self.store = store
    self.memory = memory
    self.client = client
  }

  /// Where the reading column's content starts and how wide it is.
  var columnWidth: CGFloat { max(200, width - inset * 2) }

  /// The first answer item after every prompt (or at the top of the loaded page), which carries the icon.
  static func responseStarts(_ items: [TranscriptItem]) -> Set<String> {
    var starts: Set<String> = []
    var open = true
    for item in items {
      switch item.kind {
      case .prompt, .pending: open = true
      case .older, .day, .rule, .notice: break
      default:
        if open { starts.insert(item.id) }
        open = false
      }
    }
    return starts
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
