import Foundation

public struct ChatQuote: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let messageID: String
  public let partID: String
  public let text: String
  public var comment: String
  public var commentPrompt: [JSONValue]?
  public let anchor: Anchor?
  public struct Anchor: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let exact: String
    public let coordinate: String?
    public init(start: Int, end: Int, exact: String, coordinate: String? = nil) {
      self.start = start
      self.end = end
      self.exact = exact
      self.coordinate = coordinate
    }
  }
  public init(
    id: String = UUID().uuidString, messageID: String, partID: String, text: String,
    comment: String = "", anchor: Anchor? = nil
  ) {
    self.id = id
    self.messageID = messageID
    self.partID = partID
    self.text = text
    self.comment = comment
    self.anchor = anchor
  }
  public static func selection(
    source: String, block: MarkdownBlock, range: NSRange, messageID: String, partID: String
  ) -> Self? {
    guard let mapped = block.sourceRange(for: range), NSMaxRange(mapped) <= source.utf16.count
    else { return nil }
    let exact = (source as NSString).substring(with: mapped)
    guard !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return Self(
      messageID: messageID, partID: partID, text: block.copyText(in: range).trimmingCharacters(in: .whitespacesAndNewlines),
      anchor: Anchor(start: mapped.location, end: NSMaxRange(mapped), exact: exact, coordinate: "source"))
  }
  public var document: ComposerDocument {
    get { ComposerDocument(parts: commentPrompt ?? [], fallback: comment) }
    set {
      comment = newValue.normalized.text
      commentPrompt = newValue.normalized.parts + attachmentParts
    }
  }
  public var attachmentParts: [JSONValue] {
    (commentPrompt ?? []).filter { ["image", "path"].contains($0.object?["type"]?.string ?? "") }
  }
  public var inlineIDs: [String] {
    attachmentParts.filter { $0.object?["type"]?.string == "image" }.compactMap {
      $0.object?["id"]?.string
    }
  }
  public func delivered(_ attachments: [DeliveredAttachment]) -> Self {
    var quote = self
    quote.commentPrompt = commentPrompt?.map { part in
      guard let object = part.object, let id = object["id"]?.string,
        let item = attachments.first(where: {
          $0.attachment.id == id && $0.attachment.quoteID == self.id
        })
      else { return part }
      // Only images travel inline after the prompt's files (see `inlineIDs`); a PDF stays a staged path.
      if item.inline != nil, object["type"]?.string == "image" {
        var value = object
        value["blob"] = .object(["id": .string(id), "url": .string("")])
        value.removeValue(forKey: "dataUrl")
        return .object(value)
      }
      return .object([
        "type": .string("path"), "id": .string(id), "filename": .string(item.attachment.name),
        "mime": .string(item.attachment.mime), "path": .string(item.path),
      ])
    }
    return quote
  }
  public static func read(_ value: JSONValue?) -> [Self] {
    guard let value, let data = try? JSONEncoder().encode(value) else { return [] }
    return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
  }
  public static func format(_ quotes: [Self]) -> String {
    guard !quotes.isEmpty else { return "" }
    return
      (["Comments on earlier assistant messages:"]
      + quotes.enumerated().map { index, quote in
        let comment = quote.document.expanded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return
          ([
            "\(index + 1). Quoted from message \(quote.messageID) (part \(quote.partID)):",
            quote.text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n"),
          ] + (comment.isEmpty ? [] : ["User comment: \(comment)"])
          + quote.attachmentParts.compactMap { part in
            guard let object = part.object else { return nil }
            if object["type"]?.string == "image" {
              return
                "Image attached to this comment: \(object["sourcePath"]?.string ?? object["filename"]?.string ?? "")"
            }
            return "File attached to this comment: `\(object["path"]?.string ?? "")`"
          }).joined(separator: "\n")
      }).joined(separator: "\n\n")
  }
}

extension ComposerDocument {
  /// The web's ComposerPart wire shape, also used when restoring queued quote comments.
  public var parts: [JSONValue] {
    var result: [JSONValue] = []
    var cursor = 0
    func part(_ start: Int, _ end: Int) -> [String: JSONValue] {
      [
        "type": .string("text"), "start": .number(Double(start)), "end": .number(Double(end)),
        "content": .string(
          (text as NSString).substring(with: NSRange(location: start, length: end - start))),
      ]
    }
    for span in validTokens {
      if cursor < span.start { result.append(.object(part(cursor, span.start))) }
      var value = part(span.start, span.end)
      switch span.token.kind {
      case .file, .reference:
        value["type"] = .string("file")
        value["path"] = .string(span.token.value ?? span.token.id)
      case .agent:
        value["type"] = .string("agent")
        value["name"] = .string(span.token.id)
      case .skill, .snippet:
        value["type"] = .string(span.token.kind.rawValue)
        value["id"] = .string(span.token.id)
        value["name"] = .string(String(span.token.text.dropFirst()))
        if span.token.kind == .snippet { value["expansion"] = .string(span.token.value ?? "") }
      case .session:
        value["type"] = .string("session")
        value["session"] = .object(span.token.detail ?? [:])
      case .app:
        value["type"] = .string("app")
        value["app"] = .object(span.token.detail ?? [:])
      case .command: break
      }
      result.append(.object(value))
      cursor = span.end
    }
    if cursor < text.utf16.count { result.append(.object(part(cursor, text.utf16.count))) }
    return result
  }
  public init(parts: [JSONValue], fallback: String) {
    guard !parts.isEmpty else {
      self.init(text: fallback)
      return
    }
    let text = parts.compactMap { $0.object?["content"]?.string }.joined()
    let tokens = parts.compactMap { value -> ComposerSpan? in
      guard let part = value.object, let type = part["type"]?.string,
        let content = part["content"]?.string, let start = part["start"]?.number,
        let end = part["end"]?.number, let from = Int(exactly: start), let to = Int(exactly: end)
      else { return nil }
      let token: ComposerToken
      switch type {
      case "file":
        guard let path = part["path"]?.string else { return nil }
        token = .init(kind: .file, id: path, text: content, value: path)
      case "agent":
        guard let name = part["name"]?.string else { return nil }
        token = .init(kind: .agent, id: name, text: content)
      case "skill", "snippet":
        guard let id = part["id"]?.string else { return nil }
        token = .init(
          kind: type == "skill" ? .skill : .snippet, id: id, text: content,
          value: part["expansion"]?.string)
      case "session":
        guard let session = part["session"]?.object, let id = session["id"]?.string else {
          return nil
        }
        token = .init(kind: .session, id: id, text: content, detail: session)
      case "app":
        guard let app = part["app"]?.object.flatMap(ComposerApp.init(detail:)) else { return nil }
        token = .init(kind: .app, id: app.token.id, text: content, detail: app.detail)
      default: return nil
      }
      return .init(start: from, end: to, token: token)
    }
    self.init(text: text, tokens: tokens)
    self.tokens = validTokens
  }
}

extension ConversationMessage {
  public var quotes: [ChatQuote] { ChatQuote.read(metadata?["quotes"]) }
  public var copyText: String { displayText }
  public var copyQuotes: String {
    quotes.map { quote in
      ([quote.text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")]
        + (quote.comment.isEmpty ? [] : [quote.comment])).joined(separator: "\n\n")
    }.joined(separator: "\n\n")
  }
}
