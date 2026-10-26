import Foundation
import Markdown

struct MarkdownExtensions {
  struct Span {
    enum Kind { case formula(MarkdownFormula), note(String, Int), link(String) }
    let range: NSRange
    let kind: Kind
  }
  struct Block {
    enum Kind {
      case definition
      case formula(MarkdownFormula)
      case details(NSRange, NSRange, Bool)
    }
    let range: NSRange
    let kind: Kind
  }
  struct Note {
    let id: String
    let number: Int
    let text: String
    let offsets: [Int]
  }
  let blocks: [Block]
  let notes: [Note]
  private let spans: [Span]
  private let source: String

  init(_ source: String) {
    self.source = source
    let text = source as NSString
    let lines = source.components(separatedBy: "\n")
    var starts = [0]
    for line in lines.dropLast() { starts.append(starts.last! + line.utf16.count + 1) }
    func offset(_ location: SourceLocation) -> Int {
      let line = min(max(0, location.line - 1), lines.count - 1)
      return starts[line] + String(decoding: lines[line].utf8.prefix(max(0, location.column - 1)), as: UTF8.self).utf16.count
    }
    var protected: [NSRange] = []
    var tables: [NSRange] = []
    func protect(_ node: any Markup) {
      if node is CodeBlock || node is InlineCode || node is Link, let range = node.range {
        protected.append(NSRange(location: offset(range.lowerBound), length: offset(range.upperBound) - offset(range.lowerBound)))
        return
      }
      if node is Table, let range = node.range {
        tables.append(NSRange(location: offset(range.lowerBound), length: offset(range.upperBound) - offset(range.lowerBound)))
      }
      for child in node.children { protect(child) }
    }
    protect(Document(parsing: source, options: [.disableSmartOpts]))
    func hidden(_ index: Int) -> Bool { protected.contains { NSLocationInRange(index, $0) } }
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let links = (detector?.matches(in: source, range: NSRange(location: 0, length: text.length)) ?? []).compactMap { match -> Span? in
      guard !hidden(match.range.location), let url = match.url else { return nil }
      let label = text.substring(with: match.range).lowercased()
      guard label.hasPrefix("http://") || label.hasPrefix("https://") || label.hasPrefix("www.") || url.scheme == "mailto" else { return nil }
      return Span(range: match.range, kind: .link(url.absoluteString))
    }
    protected.append(contentsOf: links.map(\.range))
    let math = Self.math(source, protected: protected, tables: tables)
    var specials = math.compactMap { span -> Block? in
      guard case .formula(let formula) = span.kind, formula.display else { return nil }
      return Block(range: span.range, kind: .formula(formula))
    }
    let tags = Self.matches("(?i)<details\\b[^>]*>|</details\\s*>", source)
    var stack: [NSTextCheckingResult] = []
    for tag in tags where !hidden(tag.range.location) {
      if text.substring(with: tag.range).hasPrefix("</") {
        guard let start = stack.popLast() else { continue }
        let inside = NSRange(location: NSMaxRange(start.range), length: tag.range.location - NSMaxRange(start.range))
        let summary = Self.matches("(?is)<summary\\b[^>]*>([\\s\\S]*?)</summary\\s*>", text.substring(with: inside)).first
        let label = summary.map { NSRange(location: inside.location + $0.range(at: 1).location, length: $0.range(at: 1).length) }
          ?? NSRange(location: inside.location, length: 0)
        let body = summary.map { inside.location + NSMaxRange($0.range) } ?? inside.location
        specials.append(Block(
          range: NSRange(location: start.range.location, length: NSMaxRange(tag.range) - start.range.location),
          kind: .details(label, NSRange(location: body, length: tag.range.location - body),
            !Self.matches("(?i)\\bopen(?:\\s|=|>)", text.substring(with: start.range)).isEmpty)))
        continue
      }
      stack.append(tag)
    }
    struct Definition {
      let id: String
      let range: NSRange
      let text: String
      let offsets: [Int]
    }
    var definitions: [Definition] = []
    var consumed = -1
    for (index, line) in lines.enumerated() where index > consumed && !hidden(starts[index]) {
      guard let match = Self.matches("^ {0,3}\\[\\^([^\\]\\n]+)\\]:[ \\t]*(.*)$", line).first else { continue }
      let id = (line as NSString).substring(with: match.range(at: 1)).lowercased()
      var body = (line as NSString).substring(with: match.range(at: 2))
      var mapping = Array(starts[index] + match.range(at: 2).location..<starts[index] + NSMaxRange(match.range(at: 2)))
      var last = index
      var next = index + 1
      while next < lines.count {
        let continuation = lines[next]
        let blank = continuation.trimmingCharacters(in: .whitespaces).isEmpty
        let indented = continuation.hasPrefix("    ") || continuation.hasPrefix("\t")
        guard indented || blank && next + 1 < lines.count && (lines[next + 1].hasPrefix("    ") || lines[next + 1].hasPrefix("\t")) else { break }
        let removed = continuation.hasPrefix("    ") ? 4 : continuation.hasPrefix("\t") ? 1 : 0
        body += "\n" + String(continuation.dropFirst(removed))
        mapping.append(starts[next] - 1)
        mapping.append(contentsOf: starts[next] + removed..<starts[next] + continuation.utf16.count)
        last = next
        next += 1
      }
      consumed = last
      let range = NSRange(location: starts[index], length: starts[last] + lines[last].utf16.count - starts[index])
      definitions.append(Definition(id: id, range: range, text: body, offsets: mapping))
      specials.append(Block(range: range, kind: .definition))
    }
    var references: [Span] = []
    var order: [String] = []
    for match in Self.matches("\\[\\^([^\\]\\n]+)\\]", source) {
      guard !hidden(match.range.location), !definitions.contains(where: { NSLocationInRange(match.range.location, $0.range) }),
        !math.contains(where: { NSLocationInRange(match.range.location, $0.range) }) else { continue }
      let id = text.substring(with: match.range(at: 1)).lowercased()
      guard definitions.contains(where: { $0.id == id }) else { continue }
      if !order.contains(id) { order.append(id) }
      references.append(Span(range: match.range, kind: .note(id, order.firstIndex(of: id)! + 1)))
    }
    notes = order.enumerated().compactMap { number, id in
      definitions.first { $0.id == id }.map { Note(id: id, number: number + 1, text: $0.text, offsets: $0.offsets) }
    }
    blocks = specials.sorted { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
    spans = (math.filter { if case .formula(let value) = $0.kind { !value.display } else { false } } + references + links)
      .sorted { $0.range.location < $1.range.location }
  }

  func decorate(_ runs: [MarkdownRun]) -> [MarkdownRun] {
    guard !spans.isEmpty else { return runs }
    var result: [MarkdownRun] = []
    var inserted = Set<Int>()
    for run in runs {
      guard !run.code, run.image == nil else { result.append(run); continue }
      var text: [UInt16] = []
      var offsets: [Int?] = []
      func flush() {
        guard !text.isEmpty else { return }
        var value = run
        value.text = String(decoding: text, as: UTF16.self)
        value.offsets = offsets
        result.append(value)
        text = []
        offsets = []
      }
      for (index, unit) in run.text.utf16.enumerated() {
        let offset = run.offsets[index]
        guard let span = offset.flatMap({ offset in spans.first { NSLocationInRange(offset, $0.range) } }) else {
          text.append(unit)
          offsets.append(offset)
          continue
        }
        flush()
        guard inserted.insert(span.range.location).inserted else { continue }
        var value = run
        value.sourceEnd = NSMaxRange(span.range)
        switch span.kind {
        case .formula(let formula):
          value.text = "\u{fffc}"
          value.formula = formula
          value.link = nil
        case .note(let id, let number):
          value.text = String(number)
          value.superscript = true
          value.link = "opencode-markdown://note/" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)
        case .link(let destination):
          value.text = (source as NSString).substring(with: span.range)
          value.link = destination
          value.sourceEnd = nil
        }
        if case .link = span.kind {
          value.offsets = (0..<value.text.utf16.count).map { span.range.location + $0 }
        } else {
          value.offsets = Array(repeating: span.range.location, count: value.text.utf16.count)
        }
        result.append(value)
      }
      flush()
    }
    return result
  }

  static func rebase(_ block: MarkdownBlock, offsets: [Int]) -> MarkdownBlock {
    func runs(_ values: [MarkdownRun]) -> [MarkdownRun] {
      values.map { run in
        var result = run
        result.offsets = run.offsets.map { $0.flatMap { offsets.indices.contains($0) ? offsets[$0] : nil } }
        result.sourceEnd = run.sourceEnd.flatMap { end in end > 0 && offsets.indices.contains(end - 1) ? offsets[end - 1] + 1 : nil }
        return result
      }
    }
    var result = block
    result.runs = runs(block.runs)
    result.children = block.children.map { rebase($0, offsets: offsets) }
    if var table = block.table {
      table.rows = table.rows.map { $0.map(runs) }
      result.table = table
    }
    return result
  }

  private static func matches(_ pattern: String, _ source: String) -> [NSTextCheckingResult] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    return expression.matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
  }
  static func quoteDepth(_ prefix: String) -> Int {
    prefix.prefix { $0.isWhitespace || $0 == ">" }.filter { $0 == ">" }.count
  }

  /// Inline `$…$` follows Pandoc's boundaries, as the web does: the opening `$` is followed by a non-space and is
  /// not glued to a preceding Latin letter (`R$`, `US$`); the closing `$` follows a non-space and precedes no
  /// letter, digit or underscore; the body has no unescaped `$`. Inline math never spans a line or a table cell, and
  /// display delimiters inside a cell stay inline so the table remains one block.
  private static func math(_ source: String, protected: [NSRange], tables: [NSRange]) -> [Span] {
    let units = Array(source.utf16)
    let text = source as NSString
    var result: [Span] = []
    var cursor = 0
    func escaped(_ index: Int) -> Bool {
      var back = index - 1
      while back >= 0 && units[back] == 92 { back -= 1 }
      return (index - back - 1) % 2 == 1
    }
    func space(_ index: Int) -> Bool { index < 0 || index >= units.count || [9, 10, 13, 32].contains(units[index]) }
    func word(_ index: Int) -> Bool {
      guard index < units.count else { return false }
      let unit = units[index]
      return (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95
    }
    func latinLetter(_ index: Int) -> Bool {
      guard index >= 0, let scalar = UnicodeScalar(units[index]) else { return false }
      return scalar.value < 0x250 && scalar.properties.isAlphabetic
    }
    // Unescaped pipes outside code delimit table cells.
    let cells = Set(tables.flatMap { table in
      (table.location..<NSMaxRange(table)).filter { index in
        units[index] == 124 && !escaped(index) && !protected.contains { NSLocationInRange(index, $0) }
      }
    })
    while cursor < units.count {
      if let range = protected.first(where: { NSLocationInRange(cursor, $0) }) { cursor = NSMaxRange(range); continue }
      let slash = units[cursor] == 92 && !escaped(cursor) && cursor + 1 < units.count && [40, 91].contains(units[cursor + 1])
      let dollar = units[cursor] == 36 && !escaped(cursor)
      guard slash || dollar else { cursor += 1; continue }
      let double = dollar && cursor + 1 < units.count && units[cursor + 1] == 36
      let cell = tables.contains { NSLocationInRange(cursor, $0) }
      let display = (double || slash && units[cursor + 1] == 91) && !cell
      let length = slash || double ? 2 : 1
      if dollar && !double && (space(cursor + 1) || latinLetter(cursor - 1)) { cursor += 1; continue }
      let close: [UInt16] = slash ? [92, units[cursor + 1] == 40 ? 41 : 93] : Array(repeating: 36, count: length)
      var end = cursor + length
      while end + close.count <= units.count {
        if protected.contains(where: { NSLocationInRange(end, $0) }) || cells.contains(end) { end = units.count; break }
        if !display && units[end] == 10 { break }
        if !escaped(end), Array(units[end..<end + close.count]) == close { break }
        end += 1
      }
      guard end + close.count <= units.count, Array(units[end..<end + close.count]) == close,
        !(dollar && !double && (space(end - 1) || word(end + 1)))
      else { cursor += length; continue }
      var body = text.substring(with: NSRange(location: cursor + length, length: end - cursor - length)).trimmingCharacters(in: .whitespacesAndNewlines)
      let currency = dollar && !double && (body.first?.isNumber == true && matches("[\\\\^_{}=+*/<>]", body).isEmpty || !matches("^[+-]?[\\d,.]+$", body).isEmpty)
      let before = text.substring(to: cursor).components(separatedBy: "\n").last ?? ""
      let after = text.substring(from: end + close.count).components(separatedBy: "\n").first ?? ""
      let container = before.replacingOccurrences(of: #"^[ \t]*(?:>[ \t]*)*"#, with: "", options: .regularExpression)
      guard !body.isEmpty, !currency, !(slash && display && (!container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) else {
        cursor = end + close.count
        continue
      }
      if display && quoteDepth(before) > 0 {
        body = body.components(separatedBy: "\n").map { line in
          (0..<quoteDepth(before)).reduce(line) { value, _ in
            value.replacingOccurrences(of: #"^[ \t]*> ?"#, with: "", options: .regularExpression)
          }
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let range = NSRange(location: cursor, length: end + close.count - cursor)
      result.append(Span(range: range, kind: .formula(MarkdownFormula(source: body, display: display))))
      cursor = NSMaxRange(range)
    }
    return result
  }
}

public enum MarkdownListMarkers {
  public static func unordered(depth: Int) -> String { ["•", "◦", "▪"][depth % 3] }
  public static func ordered(_ number: Int, depth: Int) -> String {
    if depth % 3 == 0 { return "\(number)." }
    if depth % 3 == 1 {
      var remaining = max(1, number)
      var result = ""
      while remaining > 0 {
        remaining -= 1
        result = String(UnicodeScalar(97 + remaining % 26)!) + result
        remaining /= 26
      }
      return result + "."
    }
    var remaining = number
    var result = ""
    for (value, numeral) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
      while remaining >= value { result += numeral; remaining -= value }
    }
    return result + "."
  }
}

public enum MarkdownCodeProjection {
  public static func language(_ value: String?) -> String? {
    guard let value = value?.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return nil }
    switch value {
    case "", "text", "plaintext", "plain", "mermaid": return nil
    case "sh", "shell", "zsh": return "bash"
    case "c++": return "cpp"
    case "c#": return "csharp"
    case "objc": return "objectivec"
    default: return value
    }
  }
  public static func syntax(_ classes: String) -> MarkdownSyntax? {
    if classes.contains("comment") || classes.contains("doctag") { return .comment }
    if classes.contains("function_") || classes.contains("hljs-function") { return .function }
    if classes.contains("keyword") || classes.contains("meta") { return .keyword }
    if classes.contains("hljs-section") || classes.contains("hljs-strong") { return .type }
    if classes.contains("hljs-code") || classes.contains("hljs-emphasis") { return .string }
    if classes.contains("string") || classes.contains("regexp") || classes.contains("quote") { return .string }
    if classes.contains("number") { return .number }
    if classes.contains("literal") || classes.contains("symbol") || classes.contains("bullet") { return .constant }
    if classes.contains("attr") || classes.contains("property") { return .property }
    if classes.contains("class_") || classes.contains("type") || classes.contains("tag") || classes.contains("title") { return .type }
    if classes.contains("variable") || classes.contains("params") { return .variable }
    if classes.contains("operator") { return .operator }
    if classes.contains("punctuation") { return .punctuation }
    if classes.contains("addition") { return .added }
    if classes.contains("deletion") { return .removed }
    return nil
  }
}
