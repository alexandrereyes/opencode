import OpenCodeKit
import SwiftUI

/// The latest landed Markdown parse of each text part. A part keeps its previous blocks while a newer text is
/// parsed, so a streamed answer never empties; every text part parses at most once at a time (latest wins).
@MainActor final class TranscriptParses {
  struct Result {
    var source: String
    let blocks: [MarkdownBlock]
    /// Prose joined into runs once per parse: rebuilding items never copies runs again.
    let sections: [MarkdownSection]
    var rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]
    init(source: String, blocks: [MarkdownBlock], rasters: [ResponseFormulaKey: ResponseFormulaRaster] = [:]) {
      self.source = source
      self.blocks = blocks
      sections = MarkdownBlocks.sections(blocks)
      self.rasters = rasters
    }
  }
  private var results: [String: Result] = [:]
  private var parsers: [String: LatestMarkdownParse] = [:]
  /// A parse landed with different blocks: the items must be rebuilt.
  var landed: () -> Void = {}
  /// Formula images landed for blocks already shown.
  var rasterized: () -> Void = {}
  var theme = AppTheme.selected
  var scale: CGFloat = 2

  /// The newest parse of the part and the text it came from, possibly older than the part's current text;
  /// nil until its first parse lands.
  func parsed(_ part: TranscriptPart) -> Result? {
    if let result = results[part.partID] { return result }
    guard let cached = ResponseMarkdownCache.shared.cached(part.source) else { return nil }
    let result = Result(source: part.source, blocks: cached)
    results[part.partID] = result
    return result
  }

  func blocks(_ part: TranscriptPart) -> [MarkdownBlock]? { parsed(part)?.blocks }

  func rasters(_ partID: String) -> [ResponseFormulaKey: ResponseFormulaRaster] { results[partID]?.rasters ?? [:] }

  /// Whether the part's shown blocks belong to its current text.
  func current(_ part: TranscriptPart) -> Bool { results[part.partID]?.source == part.source }

  /// Parses the part's text on the spot, without code highlighting or formula metrics, when it has no parse
  /// yet; the full parse is requested and replaces it. True when it parsed.
  func parseNow(_ part: TranscriptPart) -> Bool {
    guard results[part.partID] == nil else { return false }
    results[part.partID] = Result(source: part.source, blocks: MarkdownBlocks.parse(part.source))
    request(part)
    return true
  }

  /// Starts (or supersedes) the parse of the part's current text.
  func request(_ part: TranscriptPart) {
    let parser = parsers[part.partID] ?? LatestMarkdownParse()
    parsers[part.partID] = parser
    parser.publish = { [weak self] landed in
      guard let self else { return }
      let previous = results[part.partID]
      if previous?.blocks == landed.blocks, let previous {
        // Same blocks (whitespace, or a theme's new formula images): keep the sections, note the text.
        results[part.partID]?.source = landed.source
        guard previous.rasters != landed.rasters else { return }
        results[part.partID]?.rasters = landed.rasters
        rasterized()
        return
      }
      results[part.partID] = Result(source: landed.source, blocks: landed.blocks, rasters: landed.rasters)
      self.landed()
    }
    parser.request(part.source, theme: theme, scale: scale)
  }

  /// A new theme draws formulas in other colors; the blocks stay.
  func restyle(_ parts: [TranscriptPart]) {
    for part in parts { request(part) }
  }
}

/// Measured heights, kept with the conversation so a rebuilt transcript lays out at once. An entry is valid
/// for the same item content, width and text size.
@MainActor final class TranscriptHeights {
  private struct Entry {
    let kind: TranscriptItem.Kind
    let width: CGFloat
    let category: UIContentSizeCategory
    let height: CGFloat
  }
  private var entries: [String: Entry] = [:]

  func height(_ item: TranscriptItem, width: CGFloat, category: UIContentSizeCategory) -> CGFloat? {
    guard let entry = entries[item.id], entry.width == width, entry.category == category, entry.kind == item.kind
    else { return nil }
    return entry.height
  }

  func store(_ height: CGFloat, for item: TranscriptItem, width: CGFloat, category: UIContentSizeCategory) {
    entries[item.id] = Entry(kind: item.kind, width: width, category: category, height: height)
  }

  func removeAll() { entries.removeAll() }
}
