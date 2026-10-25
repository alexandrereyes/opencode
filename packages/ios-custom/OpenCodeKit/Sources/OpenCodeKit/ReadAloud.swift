import Foundation

/// A Markdown document read aloud: speakable text, the pieces sent to the server and their timeline.
public enum ReadAloud {
  /// Speakable text for one rendered block; `block` is the top-level block that shows it.
  public struct Segment: Sendable, Equatable {
    public let block: Int
    public let text: String
  }

  /// One synthesis request and the first block it reads.
  public struct Piece: Sendable, Equatable {
    public let text: String
    public let block: Int
  }

  /// Prose is read as written; code, tables, formulas and images are announced, not spelled out;
  /// rules, footnotes and front matter are skipped.
  public static func segments(_ blocks: [MarkdownBlock], frontMatter: Bool = false) -> [Segment] {
    blocks.enumerated().flatMap { index, block -> [Segment] in
      if frontMatter, index == 0, block.kind == .code("yaml") { return [] }
      return speech(block).map { Segment(block: block.id, text: $0) }
    }
  }

  /// The first piece is short so audio starts quickly; each later one is generated while the previous plays
  /// (the model renders about five seconds of speech per second, so each piece may be ~3× the one before).
  public static func pieces(_ segments: [Segment], limits: [Int] = [220, 650, 1_500]) -> [Piece] {
    var pieces: [Piece] = []
    var text = ""
    var block: Int?
    func limit() -> Int { limits[min(pieces.count, limits.count - 1)] }
    func flush() {
      guard let first = block, !text.isEmpty else { return }
      pieces.append(Piece(text: text, block: first))
      text = ""
      block = nil
    }
    for segment in segments {
      var rest = Substring(segment.text)
      while !rest.isEmpty {
        let joined = text.isEmpty ? 0 : 1
        let room = limit() - text.count - joined
        if rest.count <= room {
          if block == nil { block = segment.block }
          text += (text.isEmpty ? "" : "\n") + rest
          rest = ""
        } else if !text.isEmpty && room < limit() / 3 {
          flush()
        } else {
          let cut = boundary(rest, within: max(1, room))
          if block == nil { block = segment.block }
          text += (text.isEmpty ? "" : "\n") + rest[..<cut].trimmingCharacters(in: .whitespaces)
          rest = rest[cut...].drop { $0 == " " }
          flush()
        }
      }
    }
    flush()
    return pieces
  }

  /// Elapsed and total time while some pieces have no audio yet. Known pieces use their real duration; the rest use
  /// the speaking rate observed so far (or the server's estimate before any audio), so the total settles as audio arrives.
  public struct Timeline: Sendable, Equatable {
    public let characters: [Int]
    public var durations: [Double?]
    public let estimatedRate: Double

    public init(pieces: [Piece], charactersPerSecond: Double) {
      characters = pieces.map(\.text.count)
      durations = Array(repeating: nil, count: pieces.count)
      estimatedRate = charactersPerSecond
    }

    /// Characters per second at 1×.
    public var rate: Double {
      let known = zip(characters, durations).compactMap { count, duration in duration.map { (count, $0) } }
      let seconds = known.reduce(0) { $0 + $1.1 }
      guard seconds > 0 else { return estimatedRate }
      return Double(known.reduce(0) { $0 + $1.0 }) / seconds
    }
    public func duration(_ piece: Int) -> Double { durations[piece] ?? Double(characters[piece]) / rate }
    public var total: Double { characters.indices.reduce(0) { $0 + duration($1) } }
    public func start(_ piece: Int) -> Double { (0..<piece).reduce(0) { $0 + duration($1) } }
    public func time(piece: Int, offset: Double) -> Double { start(piece) + min(max(0, offset), duration(piece)) }

    /// The piece at a point of the whole document and how far into it, as a fraction of that piece.
    public func locate(_ time: Double) -> (piece: Int, fraction: Double) {
      guard !characters.isEmpty else { return (0, 0) }
      var start = 0.0
      for piece in characters.indices {
        let length = duration(piece)
        if time < start + length || piece == characters.count - 1 {
          return (piece, length > 0 ? min(1, max(0, (time - start) / length)) : 0)
        }
        start += length
      }
      return (characters.count - 1, 1)
    }
  }

  /// Above half an hour of audio the app asks before generating; the cost is only paid for what is played.
  public static let confirmationSeconds: Double = 30 * 60

  public static func cost(seconds: Double, usdPerSecond: Double) -> Double { seconds * usdPerSecond }

  /// `4:12`, or `1:02:05` past an hour.
  public static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  static func speech(_ block: MarkdownBlock) -> [String] {
    switch block.kind {
    case .paragraph, .quote:
      let text = prose(block)
      guard !text.isEmpty else { return [] }
      switch block.marker?.checked {
      case true: return ["Concluído: " + sentence(text)]
      case false: return ["Pendente: " + sentence(text)]
      default: return [block.marker == nil ? text : sentence(text)]
      }
    case .heading:
      let text = prose(block)
      return text.isEmpty ? [] : [sentence(text)]
    case .code(let language):
      let lines = block.codeDisplay.text.split(separator: "\n", omittingEmptySubsequences: false).count
      let name = language.flatMap { $0.isEmpty ? nil : $0 }.map { " em \($0)" } ?? ""
      return ["Bloco de código\(name), com \(lines) \(lines == 1 ? "linha" : "linhas")."]
    case .table:
      let header = block.table?.rows.first?.map { prose($0) }.filter { !$0.isEmpty } ?? []
      let rows = max(0, (block.table?.rows.count ?? 1) - 1)
      let columns = header.isEmpty ? "" : ", colunas " + list(header)
      return ["Tabela com \(rows) \(rows == 1 ? "linha" : "linhas")\(columns)."]
    case .image:
      let alt = prose(block)
      return [alt.isEmpty ? "Imagem." : "Imagem: " + sentence(alt)]
    case .formula: return ["Fórmula."]
    case .rule, .footnote: return []
    case .details:
      let summary = prose(block)
      return (summary.isEmpty ? [] : [sentence(summary)]) + block.children.flatMap(speech)
    }
  }

  /// Display text without generated list markers, with inline formulas named and HTML tags dropped.
  static func prose(_ block: MarkdownBlock) -> String { prose(block.runs) }

  static func prose(_ runs: [MarkdownRun]) -> String {
    let text = runs.map { run -> String in
      if run.formula != nil { return " fórmula " }
      // Footnote references are superscript numbers; their notes are not read.
      if run.superscript, run.text.allSatisfy(\.isNumber) { return "" }
      if !run.offsets.isEmpty, run.offsets.allSatisfy({ $0 == nil }), run.copy == nil { return "" }
      return run.text
    }.joined()
    return text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\u{fffc}", with: " ")
      .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: " *\\n+ *", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: " +([.,;:!?])", with: "$1", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Ends a heading or list item with a period so the voice pauses between items.
  static func sentence(_ text: String) -> String {
    guard let last = text.last, !".!?:;…".contains(last) else { return text }
    return text + "."
  }

  static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " e " + items.last!
  }

  /// The last sentence end inside `limit`, else the last line break or space, else a hard cut.
  static func boundary(_ text: Substring, within limit: Int) -> Substring.Index {
    let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
    guard end < text.endIndex else { return end }
    let window = text[..<end]
    var cursor = window.endIndex
    while cursor > window.startIndex {
      let previous = window.index(before: cursor)
      // A period followed by a space ends a sentence; one inside "3.14" or "arquivo.md" does not.
      if ".!?…".contains(window[previous]), cursor == text.endIndex || text[cursor] == " " || text[cursor] == "\n" {
        return cursor
      }
      cursor = previous
    }
    if let space = window.lastIndex(where: { $0 == " " || $0 == "\n" }), space > window.startIndex { return space }
    return end
  }
}

/// `custom.speech` in `plugin-app-custom`: the server holds the AI Gateway credential and caches each piece.
public struct SpeechInfo: Codable, Sendable, Equatable {
  public let model: String
  public let voice: String
  public let maxCharacters: Int
  public let charactersPerSecond: Double
  public let usdPerSecond: Double
  public init(model: String, voice: String, maxCharacters: Int, charactersPerSecond: Double, usdPerSecond: Double) {
    self.model = model
    self.voice = voice
    self.maxCharacters = maxCharacters
    self.charactersPerSecond = charactersPerSecond
    self.usdPerSecond = usdPerSecond
  }
}

extension OpenCodeClient {
  public func speechInfo() async throws -> SpeechInfo {
    try await rpc("custom.speech", "info", input: Empty(), timeout: 20)
  }

  /// Compressed audio for one piece; a long piece takes the model about a fifth of its duration.
  public func synthesizeSpeech(_ text: String) async throws -> Data {
    struct Input: Encodable { let text: String }
    struct Output: Decodable { let audio: String }
    let output: Output = try await rpc("custom.speech", "synthesize", input: Input(text: text), timeout: 120)
    guard let data = Data(base64Encoded: output.audio) else { throw ClientError.operation("Áudio inválido") }
    return data
  }
}
