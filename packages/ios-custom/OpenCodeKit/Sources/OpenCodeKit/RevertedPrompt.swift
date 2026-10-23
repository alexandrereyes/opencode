import Foundation

public struct RevertedPrompt: Sendable {
  public let document: ComposerDocument
  public let quotes: [ChatQuote]
  public let attachments: [DraftAttachment]
  public let bytes: [String: Data]
  public let context: RevertedContext

  public init(_ message: ConversationMessage, directory: String = "") {
    var metadata = message.metadata
    // Web presentation metadata requires both displayText and the comments array.
    if metadata?["comments"]?.array == nil {
      metadata?.removeValue(forKey: "displayText")
      metadata?.removeValue(forKey: "attachments")
    }
    document = ComposerDocument(restoring: .init(text: message.text, metadata: metadata,
      files: message.files, agents: message.agents, skills: message.skills))
    quotes = ChatQuote.read(message.metadata?["quotes"])
    let quoted = quotes.flatMap { quote in quote.inlineIDs.map { (quoteID: quote.id, id: $0) } }
    let files = message.files ?? []
    let firstQuote = files.count - quoted.count
    var attachments = (metadata?["attachments"]?.array ?? []).compactMap { value -> DraftAttachment? in
      guard let object = value.object, let path = object["path"]?.string else { return nil }
      return .init(name: object["name"]?.string ?? "Anexo", mime: object["mime"]?.string ?? "application/octet-stream",
        size: 0, remotePath: path)
    }
    attachments += quotes.flatMap { quote in
      quote.attachmentParts.compactMap { value -> DraftAttachment? in
        guard let object = value.object, object["type"]?.string == "path", let path = object["path"]?.string else { return nil }
        return .init(id: object["id"]?.string ?? UUID().uuidString, name: object["filename"]?.string ?? "Anexo",
          mime: object["mime"]?.string ?? "application/octet-stream", size: 0, remotePath: path, quoteID: quote.id)
      }
    }
    var bytes: [String: Data] = [:]
    var contextFiles: [JSONValue] = []
    for (index, value) in files.enumerated() {
      guard let file = value.object, file["mention"] == nil else { continue }
      let uri = file["source"]?.object?["uri"]?.string
      if let uri, uri.hasPrefix("file:") {
        contextFiles.append(.object(["uri": .string(uri), "name": file["name"] ?? .string("Arquivo")]))
        continue
      }
      let encoded = file["data"]?.string ?? uri.flatMap { $0.hasPrefix("data:") ? $0.components(separatedBy: ",").last : nil }
      guard let encoded, let data = Data(base64Encoded: encoded) else { continue }
      let quote = firstQuote >= 0 && index >= firstQuote ? quoted[index - firstQuote] : nil
      let attachment = DraftAttachment(id: quote?.id ?? UUID().uuidString, name: file["name"]?.string ?? "Anexo",
        mime: file["mime"]?.string ?? "application/octet-stream", size: data.count, quoteID: quote?.quoteID)
      attachments.append(attachment)
      bytes[attachment.id] = data
    }
    self.attachments = attachments
    self.bytes = bytes
    var context = RevertedContext(files: [], comments: message.metadata?["comments"], directory: directory)
    let generated = Set(context.generatedFiles.compactMap { $0.object?["uri"]?.string })
    context.files = contextFiles.filter { !generated.contains($0.object?["uri"]?.string ?? "") }
    self.context = context
  }
}

public struct RevertedContext: Codable, Sendable, Equatable {
  public var files: [JSONValue]
  public var comments: JSONValue?
  public var directory: String? = nil
  public var metadata: [String: JSONValue] { comments.map { ["comments": $0] } ?? [:] }
  public var allFiles: [JSONValue] { files + generatedFiles }
  var generatedFiles: [JSONValue] {
    let mention = try? NSRegularExpression(pattern: #"(^|[\s(\[{"'])@(\S+)"#)
    return (comments?.array ?? []).flatMap { value -> [JSONValue] in
      guard let item = value.object, let path = item["path"]?.string, let text = item["comment"]?.string,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
      let mentions = (mention?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []).map {
        (text as NSString).substring(with: $0.range(at: 2)).replacingOccurrences(of: #"[.,!?;:)}\]"']+$"#, with: "", options: .regularExpression)
      }
      return ([path] + mentions.filter { !$0.isEmpty }).enumerated().map { index, path in
        let absolute = path.hasPrefix("/") ? path : (directory ?? "") + "/" + path
        var uri = ComposerDocument.fileURI(absolute)
        if index == 0, let selection = item["selection"]?.object,
          let start = selection["startLine"]?.number.flatMap(Int.init(exactly:)),
          let end = selection["endLine"]?.number.flatMap(Int.init(exactly:)) {
          uri += "?start=\(start)&end=\(end)"
        }
        return .object(["uri": .string(uri), "name": .string(URL(fileURLWithPath: path).lastPathComponent), "mime": .string("text/plain")])
      }
    }
  }
  public var text: [String] {
    (comments?.array ?? []).compactMap { value in
      guard let item = value.object, let path = item["path"]?.string, let comment = item["comment"]?.string else { return nil }
      let selection = item["selection"]?.object
      let start = selection?["startLine"]?.number.flatMap(Int.init(exactly:))
      let end = selection?["endLine"]?.number.flatMap(Int.init(exactly:))
      let range: String
      if let start, let end { range = start == end ? "line \(start)" : "lines \(min(start, end)) through \(max(start, end))" }
      else { range = "this file" }
      return "The user made the following comment regarding \(range) of \(path): \(comment)"
    }
  }
}
