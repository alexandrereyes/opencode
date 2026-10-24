import Foundation

public struct ChatQuoteMark: Sendable, Equatable, Identifiable {
  public let quote: ChatQuote
  public let carryingMessageID: String?
  public let number: Int
  public var id: String { (carryingMessageID ?? "draft") + ":" + quote.id }
  public var pending: Bool { carryingMessageID == nil }
  public init(quote: ChatQuote, carryingMessageID: String? = nil, number: Int) {
    self.quote = quote
    self.carryingMessageID = carryingMessageID
    self.number = number
  }
}

/// Metadata projection only. Streaming text and composer keystrokes never decode quote history.
public struct ChatQuoteIndex: Sendable {
  private var saved: [String: (JSONValue, [ChatQuoteMark])] = [:]
  private var parts: [String: [ChatQuoteMark]] = [:]
  public init() {}
  public mutating func update(_ messages: [ConversationMessage]) {
    var next: [String: (JSONValue, [ChatQuoteMark])] = [:]
    var parts: [String: [ChatQuoteMark]] = [:]
    for message in messages where message.type == "user" {
      guard let value = message.metadata?["quotes"] else { continue }
      let marks = saved[message.id].flatMap { $0.0 == value ? $0.1 : nil }
        ?? ChatQuote.read(value).enumerated().map {
          ChatQuoteMark(quote: $0.element, carryingMessageID: message.id, number: $0.offset + 1)
        }
      next[message.id] = (value, marks)
      for mark in marks { parts[mark.quote.partID, default: []].append(mark) }
    }
    saved = next
    self.parts = parts
  }
  /// Dismissed sent quotes stay out of responses unless source navigation is revealing that mark.
  public func marks(
    messageID: String, partID: String, pending: [ChatQuote] = [], dismissed: Set<String> = [],
    revealing: String? = nil
  ) -> [ChatQuoteMark] {
    (parts[partID] ?? []).filter {
      $0.quote.messageID == messageID && (!dismissed.contains($0.quote.id) || $0.id == revealing)
    }
      + pending.enumerated().compactMap {
        $0.element.messageID == messageID && $0.element.partID == partID
          ? ChatQuoteMark(quote: $0.element, number: $0.offset + 1) : nil
      }
  }
  public func carried(by messageID: String) -> [ChatQuoteMark] { saved[messageID]?.1 ?? [] }
}

public enum ChatQuoteAnchoring {
  /// Like the web, anchored quotes never relocate after an edit. Only unanchored
  /// legacy quotes may recover by unique exact text. Source coordinates retain
  /// existing iOS drafts; untagged web anchors use flattened rendered UTF-16 text.
  public static func sourceRanges(_ quote: ChatQuote, source: String, blocks: [MarkdownBlock]) -> [NSRange] {
    if let anchor = quote.anchor {
      guard anchor.start >= 0, anchor.end > anchor.start else { return [] }
      let range = NSRange(location: anchor.start, length: anchor.end - anchor.start)
      if anchor.coordinate == "source" {
        return valid(anchor, in: source) ? [range] : []
      }
      let rendered = rendering(blocks)
      if valid(anchor, in: rendered.text) { return mapped(range, offsets: rendered.offsets) }
      // Earlier native releases did not tag their source-coordinate anchors.
      return valid(anchor, in: source) ? [range] : []
    }
    guard !quote.text.isEmpty else { return [] }
    let rendered = rendering(blocks)
    if rendered.text.contains(quote.text) {
      return unique(quote.text, in: rendered.text).map { mapped($0, offsets: rendered.offsets) } ?? []
    }
    return unique(quote.text, in: source).map { [$0] } ?? []
  }
  private static func valid(_ anchor: ChatQuote.Anchor, in text: String) -> Bool {
    guard anchor.start >= 0, anchor.end > anchor.start, anchor.end <= text.utf16.count else { return false }
    return (text as NSString).substring(with: NSRange(location: anchor.start, length: anchor.end - anchor.start)) == anchor.exact
  }
  private static func unique(_ exact: String, in text: String) -> NSRange? {
    let value = text as NSString
    let range = value.range(of: exact)
    guard range.location != NSNotFound,
      value.range(of: exact, range: NSRange(location: range.location + 1, length: value.length - range.location - 1)).location == NSNotFound
    else { return nil }
    return range
  }
  private static func rendering(_ blocks: [MarkdownBlock]) -> (text: String, offsets: [Int?]) {
    var units: [UInt16] = []
    var offsets: [Int?] = []
    func append(_ runs: [MarkdownRun]) {
      for run in runs {
        for (index, unit) in run.text.utf16.enumerated() where run.offsets[index] != nil {
          units.append(unit)
          offsets.append(run.offsets[index])
        }
      }
    }
    func visit(_ blocks: [MarkdownBlock]) {
      for block in blocks {
        if let table = block.table { table.rows.forEach { $0.forEach(append) } }
        else { append(block.runs) }
        visit(block.children)
        // Marked's block HTML keeps a trailing text newline outside paragraphs.
        // It participates in web offsets but has no native selectable glyph.
        units.append(10)
        offsets.append(nil)
      }
    }
    visit(blocks)
    return (String(decoding: units, as: UTF16.self), offsets)
  }
  private static func mapped(_ range: NSRange, offsets: [Int?]) -> [NSRange] {
    var result: [NSRange] = []
    for offset in offsets[range.location..<NSMaxRange(range)].compactMap({ $0 }) {
      if let last = result.last, NSMaxRange(last) == offset { result[result.count - 1].length += 1 }
      else { result.append(NSRange(location: offset, length: 1)) }
    }
    return result
  }
}
