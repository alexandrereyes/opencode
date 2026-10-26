import CryptoKit
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
  /// the rate measured on this document's generated pieces, blended with the server's learned rate while little audio
  /// exists, so the total settles within the first piece instead of jumping when each one arrives.
  public struct Timeline: Sendable, Equatable {
    public let characters: [Int]
    public var durations: [Double?]
    public let estimatedRate: Double

    public init(pieces: [Piece], charactersPerSecond: Double) {
      characters = pieces.map(\.text.count)
      durations = Array(repeating: nil, count: pieces.count)
      estimatedRate = charactersPerSecond
    }

    /// The server's learned rate weighs as much as this many measured characters, so the short first piece (often a
    /// title and an opening line, read at its own pace) nudges the estimate instead of swinging it.
    public static let priorCharacters = 1_000.0

    /// Characters per second at 1×: generated characters over their seconds, with the server's rate as a prior.
    public var rate: Double {
      let known = zip(characters, durations).compactMap { count, duration in duration.map { (Double(count), $0) } }
      let measured = known.reduce(0) { $0 + $1.0 }
      let seconds = known.reduce(0) { $0 + $1.1 }
      return (Self.priorCharacters + measured) / (Self.priorCharacters / estimatedRate + seconds)
    }
    public func duration(_ piece: Int) -> Double { durations[piece] ?? Double(characters[piece]) / rate }
    public var total: Double { characters.indices.reduce(0) { $0 + duration($1) } }
    public func start(_ piece: Int) -> Double { (0..<piece).reduce(0) { $0 + duration($1) } }
    public func time(piece: Int, offset: Double) -> Double { start(piece) + min(max(0, offset), duration(piece)) }

    /// Gives the pieces before a character offset the pace a previous listening measured (`seconds` to reach it), so a
    /// reopened document shows the time it was left at. Playing a piece replaces its share with its real length.
    public mutating func anchor(offset: Int, seconds: Double) -> Double {
      var before = 0
      var piece = 0
      while piece < characters.count - 1, before + characters[piece] <= offset { before += characters[piece]; piece += 1 }
      guard offset > 0, seconds > 0 else { return 0 }
      let pace = seconds / Double(offset)
      for index in 0..<piece where durations[index] == nil { durations[index] = Double(characters[index]) * pace }
      return time(piece: piece, offset: Double(offset - before) * pace)
    }

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

  /// Where reading stopped, as saved by `custom.speech`: an offset into the speakable text (the pieces joined), that
  /// text's hash, and the sentence being read so the place can be found again after an edit.
  public struct Bookmark: Codable, Sendable, Equatable {
    public let path: String
    public let hash: String
    public let offset: Int
    public let characters: Int
    public let sentence: String
    /// Elapsed audio at 1× when saved.
    public let seconds: Double?
    public init(path: String, hash: String, offset: Int, characters: Int, sentence: String, seconds: Double? = nil) {
      self.path = path
      self.hash = hash
      self.offset = offset
      self.characters = characters
      self.sentence = sentence
      self.seconds = seconds
    }
  }

  /// One answer of a conversation, as the footer under its last message shows it: the text parts of every message
  /// from the one after the prompt to that last message, in order, so reasoning, tool calls and their output are
  /// left out and text written between tools is read in sequence (what Copiar copies). The last message (the footer's)
  /// names the answer: it is stable once the answer completes, and the button only appears then.
  public struct Response: Sendable, Equatable {
    /// `custom.speech` position key, `message:<sessionID>/<messageID>`.
    public let key: String
    public let messageID: String
    public let text: String
  }

  public static func messageKey(sessionID: String, messageID: String) -> String { "message:\(sessionID)/\(messageID)" }

  public static func response(_ messages: [ConversationMessage], endingAt id: String, sessionID: String) -> Response? {
    guard let end = messages.firstIndex(where: { $0.id == id }) else { return nil }
    let start = messages[..<end].lastIndex(where: { $0.type == "user" }).map { $0 + 1 } ?? 0
    let text = messages[start...end].map(\.responseText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    return Response(key: messageKey(sessionID: sessionID, messageID: id), messageID: id, text: text)
  }

  /// SHA-256 of the speakable text; equal hashes mean an offset still points at the same words.
  public static func hash(_ pieces: [Piece]) -> String {
    SHA256.hash(data: Data(pieces.map(\.text).joined().utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Characters before a point inside a piece.
  public static func offset(_ pieces: [Piece], piece: Int, fraction: Double) -> Int {
    guard pieces.indices.contains(piece) else { return pieces.reduce(0) { $0 + $1.text.count } }
    let before = pieces[..<piece].reduce(0) { $0 + $1.text.count }
    return before + Int((Double(pieces[piece].text.count) * min(1, max(0, fraction))).rounded(.down))
  }

  /// The piece holding a character offset and how far into it.
  public static func location(_ pieces: [Piece], offset: Int) -> (piece: Int, fraction: Double) {
    var start = 0
    for (index, piece) in pieces.enumerated() {
      let count = piece.text.count
      if offset < start + count || index == pieces.count - 1 {
        return (index, count > 0 ? min(1, max(0, Double(offset - start) / Double(count))) : 0)
      }
      start += count
    }
    return (0, 0)
  }

  /// The sentence around an offset (up to 200 characters), saved to find the place again after an edit. Pieces end at
  /// sentence ends, so only the piece holding the offset is scanned.
  public static func sentence(_ pieces: [Piece], at offset: Int) -> String {
    guard !pieces.isEmpty else { return "" }
    let location = location(pieces, offset: offset)
    let text = pieces[location.piece].text
    let local = Int((Double(text.count) * location.fraction).rounded(.down))
    let starts = sentenceStarts(text)
    let start = starts.last { $0 <= local } ?? 0
    let end = starts.first { $0 > start } ?? text.count
    return String(text.dropFirst(start).prefix(end - start).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
  }

  /// Where to resume a saved reading in the current text, or nil to start from the beginning:
  /// - same text (hash): the saved offset;
  /// - edited text that still contains the saved sentence: the start of its occurrence nearest the old offset;
  /// - otherwise, if the old offset still falls inside the text: the sentence start nearest to it;
  /// - otherwise (the text got shorter than the old place): nil.
  public static func resume(_ bookmark: Bookmark, in pieces: [Piece]) -> Int? {
    let text = pieces.map(\.text).joined()
    if bookmark.hash == hash(pieces) { return min(bookmark.offset, text.count) }
    let target = bookmark.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    if !target.isEmpty {
      let found = occurrences(of: target, in: text)
      if let nearest = found.min(by: { abs($0 - bookmark.offset) < abs($1 - bookmark.offset) }) { return nearest }
    }
    guard bookmark.offset < text.count else { return nil }
    // Every piece starts a sentence; within a piece, sentences start after their end marks.
    var base = 0
    let starts = pieces.flatMap { piece in
      defer { base += piece.text.count }
      return sentenceStarts(piece.text).map { $0 + base }
    }
    return starts.min { abs($0 - bookmark.offset) < abs($1 - bookmark.offset) }
  }

  /// Character offsets where sentences begin: the text start and after `.`, `!`, `?`, `…` or a line break.
  static func sentenceStarts(_ text: String) -> [Int] {
    var starts = [0]
    var previous: Character?
    var pending = false
    for (index, character) in text.enumerated() {
      if pending, character != " " && character != "\n" {
        starts.append(index)
        pending = false
      }
      if character == "\n" || (character == " " && previous.map { ".!?…".contains($0) } == true) { pending = true }
      previous = character
    }
    return starts
  }

  static func occurrences(of needle: String, in text: String) -> [Int] {
    var found: [Int] = []
    var range = text.startIndex..<text.endIndex
    while let match = text.range(of: needle, range: range) {
      found.append(text.distance(from: text.startIndex, to: match.lowerBound))
      range = match.upperBound..<text.endIndex
    }
    return found
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
      if run.superscript, run.link?.hasPrefix("opencode-markdown://note/") == true { return "" }
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
  /// The saved place in a file, if any.
  public func readingPosition(_ path: String) async throws -> ReadAloud.Bookmark? {
    struct Input: Encodable { let path: String }
    struct Output: Decodable { let position: ReadAloud.Bookmark? }
    let output: Output = try await rpc("custom.speech", "getPosition", input: Input(path: path), timeout: 20)
    return output.position
  }

  public func saveReadingPosition(_ bookmark: ReadAloud.Bookmark) async throws {
    let _: ReadAloud.Bookmark = try await rpc("custom.speech", "setPosition", input: bookmark, timeout: 20)
  }

  public func clearReadingPosition(_ path: String) async throws {
    struct Input: Encodable { let path: String }
    let _: Empty = try await rpc("custom.speech", "clearPosition", input: Input(path: path), timeout: 20)
  }

  public func synthesizeSpeech(_ text: String) async throws -> Data {
    struct Input: Encodable { let text: String }
    struct Output: Decodable { let audio: String }
    let output: Output = try await rpc("custom.speech", "synthesize", input: Input(text: text), timeout: 120)
    guard let data = Data(base64Encoded: output.audio) else { throw ClientError.operation("Áudio inválido") }
    return data
  }
}
