import Foundation

public struct ConversationMatch: Sendable, Equatable, Identifiable {
  public let messageID: String
  public let partID: String
  public let range: NSRange
  public var id: String { "\(partID):\(range.location):\(range.length)" }
}

public enum ConversationSearch {
  public static func ranges(_ query: String, in text: String) -> [NSRange] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    var result: [NSRange] = []
    var start = text.startIndex
    while start < text.endIndex,
      let range = text.range(
        of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex,
        locale: Locale(identifier: "pt_BR"))
    {
      result.append(NSRange(range, in: text))
      start = range.upperBound
    }
    return result
  }
  public static func matches(_ query: String, messages: [ConversationMessage]) -> [ConversationMatch] {
    messages.flatMap { message in
      if message.type == "user" {
        return ranges(query, in: message.text ?? "").map {
          ConversationMatch(messageID: message.id, partID: "\(message.id):text:0", range: $0)
        }
      }
      guard message.type == "assistant" else { return [] }
      return (message.content ?? []).enumerated().flatMap { index, part -> [ConversationMatch] in
        guard part.type == "text", let id = message.partID(at: index) else { return [] }
        return ranges(query, in: part.text ?? "").map {
          ConversationMatch(messageID: message.id, partID: id, range: $0)
        }
      }
    }
  }
  public static func counter(index: Int?, count: Int) -> String {
    "\(index.map { $0 + 1 } ?? 0) de \(count)"
  }
  /// A bounded older-page search stops as soon as it discovers a new occurrence.
  public static func continuePaging(hasOlder: Bool, pages: Int, foundNew: Bool) -> Bool {
    hasOlder && pages < 3 && !foundNew
  }
  public static func renderedRanges(_ range: NSRange, block: MarkdownBlock) -> [NSRange] {
    var result: [NSRange] = []
    var cursor = 0
    for run in block.runs {
      for (local, offset) in run.offsets.enumerated() {
        guard let offset else { continue }
        let length = run.sourceEnd.map { max(1, $0 - offset) } ?? 1
        guard NSIntersectionRange(range, NSRange(location: offset, length: length)).length > 0 else { continue }
        let index = cursor + local
        if let last = result.last, NSMaxRange(last) == index {
          result[result.count - 1].length += 1
        } else {
          result.append(NSRange(location: index, length: 1))
        }
      }
      cursor += run.text.utf16.count
    }
    return result
  }
}

public struct SessionRename: Sendable {
  public let previous: String?
  public let title: String
  public init?(_ proposed: String, current: String?) {
    let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != (current ?? "") else { return nil }
    previous = current
    title = trimmed
  }
  public func rollback(current: String?) -> String? { current == title ? previous : current }
}
