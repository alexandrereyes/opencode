import Foundation
import Markdown

public struct MarkdownRun: Sendable, Equatable {
  public var text: String
  public var strong = false
  public var emphasis = false
  public var code = false
  public var link: String?
  /// One source UTF-16 offset per displayed UTF-16 unit; nil denotes generated list markers.
  public var offsets: [Int?]
}

public struct MarkdownBlock: Sendable, Identifiable, Equatable {
  public enum Kind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    case code(String?)
    case quote, table, rule
  }
  public let id: Int
  public let kind: Kind
  public let depth: Int
  public let runs: [MarkdownRun]
  public var text: String { runs.map(\.text).joined() }
  public func sourceRange(for selection: NSRange) -> NSRange? {
    let offsets = runs.flatMap(\.offsets)
    guard selection.location >= 0, selection.length > 0, NSMaxRange(selection) <= offsets.count
    else { return nil }
    let selected = offsets[selection.location..<NSMaxRange(selection)].compactMap { $0 }
    guard let first = selected.first, let last = selected.last else { return nil }
    return NSRange(location: first, length: last - first + 1)
  }
}

public enum MarkdownBlocks {
  public static func parse(_ source: String) -> [MarkdownBlock] {
    let document = Document(parsing: source)
    var blocks: [MarkdownBlock] = []
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    func offset(_ location: SourceLocation) -> Int {
      let line = max(0, min(location.line - 1, lines.count - 1))
      let prefix = lines.prefix(line).reduce(0) { $0 + $1.utf16.count + 1 }
      return prefix
        + String(decoding: lines[line].utf8.prefix(max(0, location.column - 1)), as: UTF8.self)
        .utf16.count
    }
    func run(
      _ text: String, node: any Markup, strong: Bool = false, emphasis: Bool = false,
      code: Bool = false, link: String? = nil
    ) -> MarkdownRun {
      let start = node.range.map { offset($0.lowerBound) } ?? 0
      let end = node.range.map { offset($0.upperBound) } ?? start
      let raw = (source as NSString).substring(
        with: NSRange(
          location: min(start, source.utf16.count),
          length: max(0, min(end, source.utf16.count) - start)))
      let found = (raw as NSString).range(of: text)
      if found.location != NSNotFound {
        return MarkdownRun(
          text: text, strong: strong, emphasis: emphasis, code: code, link: link,
          offsets: (0..<text.utf16.count).map { start + found.location + $0 })
      }
      // Escaped Markdown text need not be a contiguous substring of the source.
      var cursor = 0
      let rawText = raw as NSString
      let offsets = text.flatMap { character -> [Int?] in
        let value = String(character)
        let range = rawText.range(
          of: value, range: NSRange(location: cursor, length: rawText.length - cursor))
        guard range.location != NSNotFound else {
          return Array(repeating: nil, count: value.utf16.count)
        }
        cursor = NSMaxRange(range)
        return (0..<value.utf16.count).map { start + range.location + $0 }
      }
      return MarkdownRun(
        text: text, strong: strong, emphasis: emphasis, code: code, link: link, offsets: offsets)
    }
    func inline(
      _ node: any Markup, strong: Bool = false, emphasis: Bool = false, link: String? = nil
    ) -> [MarkdownRun] {
      if let text = node as? Markdown.Text {
        return [run(text.string, node: node, strong: strong, emphasis: emphasis, link: link)]
      }
      if let code = node as? InlineCode {
        return [
          run(code.code, node: node, strong: strong, emphasis: emphasis, code: true, link: link)
        ]
      }
      if node is SoftBreak || node is LineBreak { return [run("\n", node: node)] }
      return node.children.flatMap {
        inline(
          $0, strong: strong || node is Strong, emphasis: emphasis || node is Emphasis,
          link: (node as? Link)?.destination ?? link)
      }
    }
    func append(_ kind: MarkdownBlock.Kind, _ node: any Markup, depth: Int, prefix: String = "") {
      let runs =
        (prefix.isEmpty
          ? []
          : [MarkdownRun(text: prefix, offsets: Array(repeating: nil, count: prefix.utf16.count))])
        + inline(node)
      blocks.append(MarkdownBlock(id: blocks.count, kind: kind, depth: depth, runs: runs))
    }
    func walk(_ node: any Markup, depth: Int = 0, quoted: Bool = false, prefix: String = "") {
      if let code = node as? CodeBlock {
        blocks.append(
          MarkdownBlock(
            id: blocks.count, kind: .code(code.language), depth: depth,
            runs: [run(code.code, node: node, code: true)]))
        return
      }
      if let heading = node as? Heading {
        append(.heading(heading.level), node, depth: depth)
        return
      }
      if node is Paragraph {
        append(quoted ? .quote : .paragraph, node, depth: depth, prefix: prefix)
        return
      }
      if node is ThematicBreak {
        append(.rule, node, depth: depth)
        return
      }
      if node is Table {
        let rows = node.children.flatMap { child -> [any Markup] in
          if child is Table.Head { return [child] }
          return Array(child.children)
        }
        for row in rows {
          let runs = row.children.enumerated().flatMap { index, cell in
            (index == 0
              ? [] : [MarkdownRun(text: "  │  ", offsets: Array(repeating: nil, count: 5))])
              + inline(cell)
          }
          blocks.append(MarkdownBlock(id: blocks.count, kind: .table, depth: depth, runs: runs))
        }
        return
      }
      if node is UnorderedList || node is OrderedList {
        for (index, item) in node.children.enumerated() {
          for (childIndex, child) in item.children.enumerated() {
            let number = (node as? OrderedList)?.startIndex ?? 1
            walk(
              child, depth: depth + 1, quoted: quoted,
              prefix: childIndex == 0
                ? (node is OrderedList ? "\(number + UInt(index)). " : "• ") : "")
          }
        }
        return
      }
      for child in node.children {
        walk(child, depth: depth, quoted: quoted || node is BlockQuote, prefix: prefix)
      }
    }
    walk(document)
    return blocks
  }
}
