import Foundation

public enum ComposerTokenKind: String, Codable, Sendable {
  case file, reference, session, agent, command, skill, snippet, app
}

public struct ComposerToken: Codable, Sendable, Equatable {
  public var kind: ComposerTokenKind
  public var id: String
  public var text: String
  public var value: String?
  public var detail: [String: JSONValue]?
  public init(
    kind: ComposerTokenKind, id: String, text: String, value: String? = nil,
    detail: [String: JSONValue]? = nil
  ) {
    self.kind = kind
    self.id = id
    self.text = text
    self.value = value
    self.detail = detail
  }
}

public struct ComposerSpan: Codable, Sendable, Equatable {
  public var start: Int
  public var end: Int
  public var token: ComposerToken
  public init(start: Int, end: Int, token: ComposerToken) {
    self.start = start
    self.end = end
    self.token = token
  }
  public var range: NSRange { NSRange(location: start, length: end - start) }
}

public struct ComposerDocument: Codable, Sendable, Equatable {
  public var text: String
  public var tokens: [ComposerSpan]
  public init(text: String = "", tokens: [ComposerSpan] = []) {
    self.text = text
    self.tokens = tokens
  }
  public init(restoring payload: InboxItem.Payload) {
    let saved = payload.metadata?["composerTokens"].flatMap { try? JSONEncoder().encode($0) }
      .flatMap { try? JSONDecoder().decode([ComposerSpan].self, from: $0) }
    if let saved {
      self.init(text: payload.displayText, tokens: saved)
      return
    }
    let files = (payload.files ?? []).compactMap { value -> ComposerSpan? in
      guard let object = value.object, let uri = object["source"]?.object?["uri"]?.string,
        let url = URL(string: uri), url.isFileURL
      else { return nil }
      return Self.restoreSpan(object["mention"], kind: .file, id: url.path, value: url.path)
    }
    let agents = (payload.agents ?? []).compactMap { value -> ComposerSpan? in
      guard let object = value.object, let name = object["name"]?.string else { return nil }
      return Self.restoreSpan(object["mention"], kind: .agent, id: name)
    }
    let skills = (payload.skills ?? []).compactMap { value -> ComposerSpan? in
      guard let object = value.object, let id = object["id"]?.string else { return nil }
      return Self.restoreSpan(object["mention"], kind: .skill, id: id)
    }
    let sessions = (payload.metadata?["sessions"]?.array ?? []).compactMap {
      value -> ComposerSpan? in
      guard let object = value.object, let session = object["session"]?.object,
        let id = session["id"]?.string
      else { return nil }
      return Self.restoreSpan(
        .object([
          "start": object["start"] ?? .null, "end": object["end"] ?? .null,
          "text": object["content"] ?? .null,
        ]), kind: .session, id: id, detail: session)
    }
    let apps = (payload.metadata?["apps"]?.array ?? []).compactMap { value -> ComposerSpan? in
      guard let object = value.object, let app = object["app"]?.object.flatMap(ComposerApp.init(detail:))
      else { return nil }
      return Self.restoreSpan(
        .object([
          "start": object["start"] ?? .null, "end": object["end"] ?? .null,
          "text": object["content"] ?? .null,
        ]), kind: .app, id: app.token.id, detail: app.detail)
    }
    self.init(text: payload.displayText, tokens: files + agents + skills + sessions + apps)
    tokens = validTokens
  }
  private static func restoreSpan(
    _ mention: JSONValue?, kind: ComposerTokenKind, id: String,
    value: String? = nil, detail: [String: JSONValue]? = nil
  ) -> ComposerSpan? {
    guard let mention = mention?.object, let from = mention["start"]?.number,
      let to = mention["end"]?.number, let start = Int(exactly: from), let end = Int(exactly: to),
      let text = mention["text"]?.string
    else { return nil }
    return .init(
      start: start, end: end,
      token: .init(kind: kind, id: id, text: text, value: value, detail: detail))
  }
  public var validTokens: [ComposerSpan] {
    var end = 0
    let source = text as NSString
    return tokens.sorted { $0.start < $1.start }.filter { span in
      guard span.start >= end, span.end > span.start, span.end <= source.length,
        source.substring(with: span.range) == span.token.text
      else { return false }
      end = span.end
      return true
    }
  }
  public var normalized: Self {
    // Normalize individual runs, preserving UTF-16 offsets even when CRLF precedes a token.
    var result = Self()
    var offset = 0
    for span in validTokens {
      result.text += Self.normalize(
        (text as NSString).substring(
          with:
            NSRange(location: offset, length: span.start - offset)))
      let start = result.text.utf16.count
      var token = span.token
      token.text = Self.normalize(token.text)
      result.text += token.text
      result.tokens.append(.init(start: start, end: result.text.utf16.count, token: token))
      offset = span.end
    }
    result.text += Self.normalize((text as NSString).substring(from: offset))
    return result
  }
  /// Map the persisted UTF-16 cursor to the editor's single-character tokens.
  public func editorOffset(_ offset: Int) -> Int {
    var removed = 0
    for span in validTokens {
      if offset <= span.start { break }
      if offset < span.end { return span.start - removed + 1 }
      removed += span.range.length - 1
    }
    return min(max(0, offset), text.utf16.count) - removed
  }
  public func documentOffset(_ offset: Int) -> Int {
    var removed = 0
    for span in validTokens {
      if offset <= span.start - removed { break }
      removed += span.range.length - 1
    }
    return min(max(0, offset + removed), text.utf16.count)
  }
  public var expanded: Self {
    let source = normalized
    var result = Self()
    var offset = 0
    for span in source.validTokens {
      result.text += (source.text as NSString).substring(
        with:
          NSRange(location: offset, length: span.start - offset))
      let start = result.text.utf16.count
      result.text +=
        span.token.kind == .snippet ? Self.normalize(span.token.value ?? "") : span.token.text
      if span.token.kind != .snippet {
        result.tokens.append(.init(start: start, end: result.text.utf16.count, token: span.token))
      }
      offset = span.end
    }
    result.text += (source.text as NSString).substring(from: offset)
    return result
  }
  public static func normalize(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }
  public static func fileURI(_ path: String) -> String {
    // URL(fileURLWithPath:) applies the client's filesystem Unicode normalization.
    // Remote filenames must retain the server's exact code points instead.
    var components = URLComponents()
    components.scheme = "file"
    components.host = ""
    components.path = path
    return components.string!
  }
}

public struct ComposerTrigger: Sendable, Equatable {
  private static let expression = try! NSRegularExpression(pattern: #"(^|[\s(\[{\"'])\s*([@/$#])([^\s@$#]*)$"#)
  public let character: String
  public let query: String
  public let range: NSRange
  public static func detect(in text: NSString, cursor: Int) -> Self? {
    guard cursor > 0, cursor <= text.length else { return nil }
    // Only the current word can be a query; no document/token scan on a caret move.
    var start = cursor
    while start > 0 {
      // A pasted megabyte-sized word must not become a megabyte-sized suggestion query.
      if cursor - start >= 2048 { return nil }
      let unit = text.character(at: start - 1)
      if unit == 0xFFFC || unit == 32 || unit == 10 || unit == 13 || unit == 9 { break }
      start -= 1
    }
    let word = text.substring(with: NSRange(location: start, length: cursor - start))
    guard let trigger = detect(in: ComposerDocument(text: word), cursor: word.utf16.count),
      trigger.character != "/" || start + trigger.range.location == 0 else { return nil }
    return Self(character: trigger.character, query: trigger.query,
                range: NSRange(location: start + trigger.range.location, length: trigger.range.length))
  }
  public static func detect(in document: ComposerDocument, cursor: Int) -> Self? {
    guard cursor >= 0, cursor <= document.text.utf16.count,
      !document.validTokens.contains(where: { cursor > $0.start && cursor <= $0.end })
    else { return nil }
    let prefix = (document.text as NSString).substring(to: cursor)
    guard
      let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: cursor))
    else { return nil }
    let marker = (prefix as NSString).substring(with: match.range(at: 2))
    let start = match.range(at: 2).location
    guard marker != "/" || start == 0 else { return nil }
    return Self(
      character: marker, query: (prefix as NSString).substring(with: match.range(at: 3)),
      range: NSRange(location: start, length: cursor - start))
  }
}

public enum ComposerDispatch: Sendable, Equatable {
  case prompt
  case command(String, String)
  case local(String)
  public static func resolve(_ document: ComposerDocument) -> Self {
    guard let span = document.validTokens.first, span.start == 0, span.token.kind == .command else {
      return .prompt
    }
    if span.token.value == "client" { return .local(span.token.id) }
    return .command(
      span.token.id,
      (document.text as NSString).substring(from: span.end)
        .trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
