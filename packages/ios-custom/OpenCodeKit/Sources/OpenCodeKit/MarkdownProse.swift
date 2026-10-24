import Foundation

/// Consecutive prose blocks of one text part, rendered as a single selectable text.
///
/// `block` joins the segments' runs with generated newline separators (no source offsets), so source
/// mapping, quotations, search and copying work across segments exactly as they do within one block.
public struct MarkdownProse: Sendable, Equatable, Identifiable {
  public let segments: [MarkdownBlock]
  public let block: MarkdownBlock
  /// Each segment's UTF-16 range in `block`'s displayed text.
  public let ranges: [NSRange]
  /// Points before each segment; the caller lays out the first one's.
  public let spacing: [Double]
  public var id: Int { block.id }

  public init(_ segments: [MarkdownBlock], after previous: MarkdownBlock? = nil) {
    var runs: [MarkdownRun] = []
    var ranges: [NSRange] = []
    var spacing: [Double] = []
    var cursor = 0
    for (index, segment) in segments.enumerated() {
      let before = index == 0 ? previous : segments[index - 1]
      spacing.append(MarkdownBlocks.spacing(segment, after: before))
      if index > 0 {
        // Lists copy one item per line; other blocks copy as Markdown paragraphs.
        runs.append(MarkdownRun(text: "\n", copy: segment.marker != nil && before?.marker != nil ? "\n" : "\n\n", offsets: [nil]))
        cursor += 1
      }
      let content = segment.kind == .rule ? [MarkdownRun(text: " ", copy: "---", offsets: [nil])] : segment.runs
      let length = content.reduce(0) { $0 + $1.text.utf16.count }
      ranges.append(NSRange(location: cursor, length: length))
      runs += content
      cursor += length
    }
    self.segments = segments
    self.ranges = ranges
    self.spacing = spacing
    block = MarkdownBlock(id: segments.first?.id ?? 0, kind: .paragraph, depth: 0, runs: runs)
  }
}

public enum MarkdownSection: Sendable, Equatable, Identifiable {
  case prose(MarkdownProse)
  case block(MarkdownBlock)
  public var id: Int {
    switch self {
    case .prose(let prose): prose.id
    case .block(let block): block.id
    }
  }
}

extension MarkdownBlocks {
  /// Groups consecutive paragraphs, headings, list items, quotations and rules. Code, tables, media,
  /// formulas, disclosures and notes keep their own views. While a response streams every block stays
  /// apart: each completed paragraph would otherwise re-lay out the whole joined text.
  public static func sections(_ blocks: [MarkdownBlock], streaming: Bool = false) -> [MarkdownSection] {
    var sections: [MarkdownSection] = []
    var prose: [MarkdownBlock] = []
    var previous: MarkdownBlock?
    func flush() {
      guard !prose.isEmpty else { return }
      sections.append(.prose(MarkdownProse(prose, after: previous)))
      previous = prose.last
      prose = []
    }
    for block in blocks {
      guard isProse(block) else {
        flush()
        sections.append(.block(block))
        previous = block
        continue
      }
      if streaming { flush() }
      prose.append(block)
    }
    flush()
    return sections
  }

  public static func isProse(_ block: MarkdownBlock) -> Bool {
    switch block.kind {
    case .paragraph, .heading, .quote, .rule: true
    default: false
    }
  }

  /// Points between a block and its predecessor.
  public static func spacing(_ block: MarkdownBlock, after previous: MarkdownBlock?) -> Double {
    guard let previous else { return 0 }
    if case .heading = block.kind { return 20 }
    if block.marker != nil && previous.marker != nil { return 10 }
    if isFootnote(block) && !isFootnote(previous) { return 20 }
    return 14
  }

  private static func isFootnote(_ block: MarkdownBlock) -> Bool {
    if case .footnote = block.kind { return true }
    return false
  }
}
