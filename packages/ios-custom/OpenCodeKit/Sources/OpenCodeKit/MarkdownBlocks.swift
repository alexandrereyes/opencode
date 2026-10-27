import Foundation
import Markdown

public struct MarkdownRun: Sendable, Equatable {
  public var text: String
  public var strong = false
  public var emphasis = false
  public var strikethrough = false
  public var code = false
  public var link: String?
  public var image: String? = nil
  public var formula: MarkdownFormula? = nil
  public var syntax: MarkdownSyntax? = nil
  public var superscript = false
  /// `<sub>` and `<small>`: smaller, secondary text.
  public var small = false
  public var underline = false
  public var sourceEnd: Int? = nil
  /// Copied in place of the displayed text, for generated separators between prose blocks.
  public var copy: String? = nil
  /// One source UTF-16 offset per displayed UTF-16 unit; nil denotes generated list markers.
  public var offsets: [Int?]
}

public struct MarkdownBlock: Sendable, Identifiable, Equatable {
  public enum Kind: Sendable, Equatable {
    case paragraph
    case heading(Int)
    case code(String?)
    case image(String)
    case quote, table, rule, formula
    case details(String, Bool)
    case footnote(String, Int)
  }
  public let id: Int
  public let kind: Kind
  public let depth: Int
  public var runs: [MarkdownRun]
  public var quoteDepth = 0
  public var indent: Double = 0
  public var marker: MarkdownMarker? = nil
  public var table: MarkdownTable? = nil
  public var alignment: MarkdownTable.Alignment = .leading
  public var children: [MarkdownBlock] = []
  public var text: String { runs.map(\.text).joined() }
  public var copyText: String { runs.map { $0.formula?.source ?? $0.copy ?? $0.text }.joined() }
  public var codeDisplay: MarkdownBlock {
    guard case .code = kind, let last = runs.indices.last, runs[last].text.hasSuffix("\n") else { return self }
    var result = self
    result.runs[last].text.removeLast()
    result.runs[last].offsets.removeLast()
    if result.runs[last].text.isEmpty { result.runs.removeLast() }
    return result
  }
  public func copyText(in selection: NSRange) -> String {
    var cursor = 0
    return runs.map { run in
      defer { cursor += run.text.utf16.count }
      let range = NSIntersectionRange(selection, NSRange(location: cursor, length: run.text.utf16.count))
      guard range.length > 0 else { return "" }
      return run.formula?.source ?? run.copy
        ?? (run.text as NSString).substring(with: NSRange(location: range.location - cursor, length: range.length))
    }.joined()
  }
  public func cell(_ runs: [MarkdownRun], alignment: MarkdownTable.Alignment = .leading) -> MarkdownBlock {
    var result = self
    result.runs = runs
    result.table = nil
    result.marker = nil
    result.quoteDepth = 0
    result.alignment = alignment
    return result
  }
  public func sourceRange(for selection: NSRange) -> NSRange? {
    let offsets = runs.flatMap(\.offsets)
    guard selection.location >= 0, selection.length > 0, NSMaxRange(selection) <= offsets.count
    else { return nil }
    let selected = offsets[selection.location..<NSMaxRange(selection)].compactMap { $0 }
    guard let first = selected.first, let last = selected.last else { return nil }
    var cursor = 0
    let end = runs.reduce(last + 1) { end, run in
      defer { cursor += run.text.utf16.count }
      guard let sourceEnd = run.sourceEnd,
        NSIntersectionRange(selection, NSRange(location: cursor, length: run.text.utf16.count)).length > 0
      else { return end }
      return max(end, sourceEnd)
    }
    return NSRange(location: first, length: end - first)
  }
}

public struct MarkdownFormula: Sendable, Equatable {
  public let source: String
  public let display: Bool
  public var metrics: Metrics? = nil
  public struct Metrics: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public let baseline: Double
    public init(width: Double, height: Double, baseline: Double) {
      self.width = width
      self.height = height
      self.baseline = baseline
    }
  }
}

public struct MarkdownMarker: Sendable, Equatable {
  public let width: Double
  public let first: Bool
  public let checked: Bool?
}

public enum MarkdownSyntax: String, Sendable, Equatable {
  case keyword, string, comment, function, property, type, constant, number, variable, punctuation, `operator`, added, removed
}

public struct MarkdownTable: Sendable, Equatable {
  public enum Alignment: Sendable, Equatable { case leading, center, trailing }
  public let alignments: [Alignment]
  public var rows: [[[MarkdownRun]]]
  public let markdown: String
  public func delimited(_ separator: String) -> String {
    rows.map { row in
      row.map { cell in
        let text = cell.map { $0.formula?.source ?? $0.text }.joined()
        return text.contains(separator) || text.contains("\"") || text.contains("\n")
          ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
      }.joined(separator: separator)
    }.joined(separator: "\n")
  }

  /// Column widths for `available` points. Each column wants its unwrapped `natural` width; with wrapping, a
  /// column never narrows below `minimum` (its longest word), so words and numbers only break between words.
  /// Columns share the space by water-filling: the narrow ones keep their natural width, the rest get an equal
  /// level. When even the minimums do not fit, the table keeps them and scrolls horizontally. Leftover space is
  /// shared equally.
  public static func columnWidths(natural: [Double], minimum: [Double], available: Double, wrap: Bool) -> [Double] {
    guard !natural.isEmpty else { return [] }
    let floors = zip(natural, minimum).map { Swift.min($0, $1) }
    let widths: [Double] = {
      guard wrap, natural.reduce(0, +) > available else { return natural }
      guard floors.reduce(0, +) < available else { return floors }
      func total(_ level: Double) -> Double { zip(natural, floors).reduce(0) { $0 + Swift.min($1.0, Swift.max($1.1, level)) } }
      var low = 0.0
      var high = natural.max() ?? 0
      for _ in 0..<40 {
        let level = (low + high) / 2
        if total(level) > available { high = level } else { low = level }
      }
      return zip(natural, floors).map { Swift.min($0, Swift.max($1, low)) }
    }()
    let extra = Swift.max(0, available - widths.reduce(0, +)) / Double(widths.count)
    return widths.map { $0 + extra }
  }
}

public enum MarkdownBlocks {
  public static func parse(_ source: String) -> [MarkdownBlock] {
    let extensions = MarkdownExtensions(source)
    var blocks: [MarkdownBlock] = []
    var nextID = 0
    var regionStart = 0
    var lines = [String]()
    var starts = [Int]()
    func make(_ kind: MarkdownBlock.Kind, depth: Int, runs: [MarkdownRun], quoteDepth: Int = 0,
      indent: Double = 0, marker: MarkdownMarker? = nil, table: MarkdownTable? = nil,
      children: [MarkdownBlock] = []) -> MarkdownBlock {
      defer { nextID += 1 }
      return MarkdownBlock(id: nextID, kind: kind, depth: depth, runs: runs,
        quoteDepth: quoteDepth, indent: indent, marker: marker, table: table, children: children)
    }
    func offset(_ location: SourceLocation) -> Int {
      let line = max(0, min(location.line - 1, lines.count - 1))
      return regionStart + starts[line]
        + String(decoding: lines[line].utf8.prefix(max(0, location.column - 1)), as: UTF8.self)
        .utf16.count
    }
    func run(_ text: String, node: any Markup, style: InlineStyle = InlineStyle()) -> MarkdownRun {
      let start = node.range.map { offset($0.lowerBound) } ?? 0
      let end = node.range.map { offset($0.upperBound) } ?? start
      let raw = (source as NSString).substring(
        with: NSRange(
          location: min(start, source.utf16.count),
          length: max(0, min(end, source.utf16.count) - start)))
      let found = (raw as NSString).range(of: text)
      if found.location != NSNotFound {
        return style.run(text, offsets: (0..<text.utf16.count).map { start + found.location + $0 })
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
      return style.run(text, offsets: offsets)
    }
    func inline(_ node: any Markup, style: InlineStyle = InlineStyle()) -> [MarkdownRun] {
      if let image = node as? Markdown.Image, let destination = image.source {
        var value = run(image.plainText, node: node)
        value.image = destination
        return [value]
      }
      if let html = node as? InlineHTML {
        let images = HTMLImages.parse(html.rawHTML).map { image in
          var value = run(image.name, node: node)
          value.image = image.source
          return value
        }
        return images.isEmpty ? [run(html.rawHTML, node: node, style: style)] : images
      }
      if let text = node as? Markdown.Text {
        return [run(text.string, node: node, style: style)]
      }
      if let code = node as? InlineCode {
        var value = style
        value.code = true
        return [run(code.code, node: node, style: value)]
      }
      if node is SoftBreak { return [run(" ", node: node)] }
      if node is LineBreak { return [run("\n", node: node)] }
      var inner = style
      inner.strong = style.strong || node is Strong
      inner.emphasis = style.emphasis || node is Emphasis
      inner.strikethrough = style.strikethrough || node is Strikethrough
      inner.link = (node as? Link)?.destination ?? style.link
      return children(Array(node.children), style: inner)
    }
    /// Siblings in order; a known inline HTML tag and its closing sibling style the nodes between them.
    func children(_ nodes: [any Markup], style: InlineStyle) -> [MarkdownRun] {
      var result: [MarkdownRun] = []
      var index = 0
      while index < nodes.count {
        if let html = nodes[index] as? InlineHTML, let token = HTMLInlineTag.parse(html.rawHTML), !token.closing {
          if token.tag == .lineBreak, let range = html.range {
            var value = style.run("\n", offsets: [offset(range.lowerBound)])
            value.sourceEnd = offset(range.upperBound)
            result.append(value)
            index += 1
            continue
          }
          if let close = HTMLInlineTag.closing(token, in: nodes, after: index) {
            result += children(Array(nodes[(index + 1)..<close]), style: style.applying(token.tag))
            index = close + 1
            continue
          }
        }
        result += inline(nodes[index], style: style)
        index += 1
      }
      return result
    }
    func append(_ kind: MarkdownBlock.Kind, _ node: any Markup, depth: Int, prefix: String = "",
      quoteDepth: Int = 0, indent: Double = 0, marker: MarkdownMarker? = nil) {
      let runs =
        (prefix.isEmpty
          ? []
          : [MarkdownRun(text: prefix, offsets: Array(repeating: nil, count: prefix.utf16.count))])
        + extensions.decorate(inline(node))
      appendRuns(runs, kind: kind, depth: depth, quoteDepth: quoteDepth, indent: indent, marker: marker)
    }
    func appendRuns(_ runs: [MarkdownRun], kind: MarkdownBlock.Kind, depth: Int,
      quoteDepth: Int = 0, indent: Double = 0, marker: MarkdownMarker? = nil) {
      var text: [MarkdownRun] = []
      for value in runs {
        guard let image = value.image else { text.append(value); continue }
        if !text.isEmpty {
          blocks.append(make(kind, depth: depth, runs: text, quoteDepth: quoteDepth, indent: indent, marker: marker))
          text = []
        }
        blocks.append(make(.image(image), depth: depth, runs: [value], quoteDepth: quoteDepth, indent: indent))
      }
      if !text.isEmpty || runs.isEmpty {
        blocks.append(make(kind, depth: depth, runs: text, quoteDepth: quoteDepth, indent: indent, marker: marker))
      }
    }
    func walk(_ node: any Markup, depth: Int = 0, quoteDepth: Int = 0, prefix: String = "",
      indent: Double = 0, marker: MarkdownMarker? = nil) {
      if let html = node as? HTMLBlock {
        let images = HTMLImages.parse(html.rawHTML)
        if images.isEmpty {
          appendRuns([run(html.rawHTML, node: node)], kind: .paragraph, depth: depth,
            quoteDepth: quoteDepth, indent: indent, marker: marker)
        }
        for image in images {
          blocks.append(make(.image(image.source), depth: depth, runs: [run(image.name, node: node)],
            quoteDepth: quoteDepth, indent: indent))
        }
        return
      }
      if let code = node as? CodeBlock {
        blocks.append(
          make(.code(code.language), depth: depth, runs: [run(code.code, node: node, style: InlineStyle(code: true))],
            quoteDepth: quoteDepth, indent: indent))
        return
      }
      if let heading = node as? Heading {
        append(.heading(heading.level), node, depth: depth, quoteDepth: quoteDepth, indent: indent)
        return
      }
      if node is Paragraph {
        append(quoteDepth > 0 ? .quote : .paragraph, node, depth: depth, prefix: prefix,
          quoteDepth: quoteDepth, indent: indent, marker: marker)
        return
      }
      if node is ThematicBreak {
        append(.rule, node, depth: depth, quoteDepth: quoteDepth, indent: indent)
        return
      }
      if let table = node as? Table {
        let rows = node.children.flatMap { child -> [any Markup] in
          if child is Table.Head { return [child] }
          return Array(child.children)
        }
        let cells = rows.map { row in row.children.map { extensions.decorate(inline($0)) } }
        if let header = cells.first {
          let runs = header.enumerated().flatMap { index, cell in
            (index == 0
              ? [] : [MarkdownRun(text: "  │  ", offsets: Array(repeating: nil, count: 5))])
              + cell
          }
          let range = node.range.map { NSRange(location: offset($0.lowerBound), length: offset($0.upperBound) - offset($0.lowerBound)) }
          blocks.append(make(.table, depth: depth, runs: runs, quoteDepth: quoteDepth, indent: indent,
            table: MarkdownTable(alignments: table.columnAlignments.map {
              switch $0 { case .center: .center; case .right: .trailing; default: .leading }
            }, rows: cells, markdown: range.map { (source as NSString).substring(with: $0) } ?? "")))
        }
        return
      }
      if node is UnorderedList || node is OrderedList {
        let width: Double = node is OrderedList ? 32 : 20
        for (index, item) in node.children.enumerated() {
          for (childIndex, child) in item.children.enumerated() {
            let number = (node as? OrderedList)?.startIndex ?? 1
            let checked = (item as? ListItem)?.checkbox.map { $0 == .checked }
            let nested = child is UnorderedList || child is OrderedList
            let value = checked.map { $0 ? "☑" : "☐" }
              ?? (node is OrderedList ? MarkdownListMarkers.ordered(Int(number) + index, depth: depth) : MarkdownListMarkers.unordered(depth: depth))
            walk(
              child, depth: depth + 1, quoteDepth: quoteDepth,
              prefix: childIndex == 0 && !nested ? value + "\t" : "",
              indent: indent + (nested ? width : 0),
              marker: nested ? nil : MarkdownMarker(width: width, first: childIndex == 0, checked: checked))
          }
        }
        return
      }
      for child in node.children {
        walk(child, depth: depth, quoteDepth: quoteDepth + (node is BlockQuote ? 1 : 0),
          prefix: prefix, indent: indent, marker: marker)
      }
    }
    func commonMark(_ range: NSRange) {
      guard range.length > 0 else { return }
      regionStart = range.location
      let text = (source as NSString).substring(with: range)
      lines = text.components(separatedBy: "\n")
      starts = [0]
      for line in lines.dropLast() { starts.append(starts.last! + line.utf16.count + 1) }
      walk(Document(parsing: text, options: [.disableSmartOpts]))
    }
    func region(_ range: NSRange) {
      var cursor = range.location
      for special in extensions.blocks where special.range.location >= range.location && NSMaxRange(special.range) <= NSMaxRange(range) {
        guard special.range.location >= cursor else { continue }
        commonMark(NSRange(location: cursor, length: special.range.location - cursor))
        switch special.kind {
        case .definition: break
        case .formula(let formula):
          var value = MarkdownRun(text: "\u{fffc}", offsets: [special.range.location])
          value.formula = formula
          value.sourceEnd = NSMaxRange(special.range)
          let prefix = (source as NSString).substring(to: special.range.location).components(separatedBy: "\n").last ?? ""
          blocks.append(make(.formula, depth: 0, runs: [value], quoteDepth: MarkdownExtensions.quoteDepth(prefix)))
        case .details(let summary, let body, let open):
          let label = (source as NSString).substring(with: summary)
          var disclosure = make(.details(label.isEmpty ? "Detalhes" : label, open), depth: 0, runs: [])
          let previous = blocks
          blocks = []
          region(body)
          let children = blocks
          blocks = previous
          let runs = MarkdownBlocks.parse(label).flatMap(\.runs).map { value in
            var copy = value
            copy.offsets = value.offsets.map { $0.map { $0 + summary.location } }
            return copy
          }
          disclosure.runs = runs
          disclosure.children = children
          blocks.append(disclosure)
        }
        cursor = NSMaxRange(special.range)
      }
      commonMark(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
    }
    region(NSRange(location: 0, length: source.utf16.count))
    for note in extensions.notes {
      let children = MarkdownBlocks.parse(note.text).map { MarkdownExtensions.rebase($0, offsets: note.offsets) }
      blocks.append(make(.footnote(note.id, note.number), depth: 0,
        runs: children.flatMap(\.runs), children: children))
    }
    return blocks
  }
}

/// Inline formatting inherited by a node's text, from Markdown emphasis and the supported HTML tags.
struct InlineStyle {
  var strong = false
  var emphasis = false
  var strikethrough = false
  var code = false
  var small = false
  var superscript = false
  var underline = false
  var link: String? = nil

  func applying(_ tag: HTMLInlineTag) -> InlineStyle {
    var result = self
    switch tag {
    case .small: result.small = true
    case .superscript: result.superscript = true
    case .code: result.code = true
    case .strong: result.strong = true
    case .emphasis: result.emphasis = true
    case .underline: result.underline = true
    case .strikethrough: result.strikethrough = true
    case .lineBreak: break
    }
    return result
  }

  func run(_ text: String, offsets: [Int?]) -> MarkdownRun {
    var value = MarkdownRun(
      text: text, strong: strong, emphasis: emphasis, strikethrough: strikethrough, code: code, link: link, offsets: offsets)
    value.small = small
    value.superscript = superscript
    value.underline = underline
    return value
  }
}

extension MarkdownSyntax {
  /// The theme role that colors this token, for code drawn outside the response renderer (the Mac file viewer).
  public var role: ThemeRole {
    switch self {
    case .keyword: .syntaxKeyword
    case .string: .syntaxString
    case .comment: .syntaxComment
    case .function: .syntaxFunction
    case .property: .syntaxProperty
    case .type: .syntaxType
    case .constant: .syntaxConstant
    case .number: .syntaxNumber
    case .variable: .syntaxVariable
    case .punctuation: .syntaxPunctuation
    case .operator: .syntaxOperator
    case .added: .syntaxAdded
    case .removed: .syntaxRemoved
    }
  }
}
