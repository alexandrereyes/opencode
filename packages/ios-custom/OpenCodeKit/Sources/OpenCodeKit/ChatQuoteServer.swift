import Foundation

/// The `custom.quotes` RPC contract (`packages/plugin-app-custom/docs/quotes.md`): pending quotes of a
/// Session live on the server so the web and the iPhone edit the same drafts.
public enum QuoteServer {
  public struct Attachment: Codable, Sendable, Equatable {
    public let id: String
    public let mime: String
    public let filename: String?
    public let size: Int
  }
  public struct Quote: Codable, Sendable, Equatable {
    public let id: String
    public let messageID: String
    public let partID: String
    public let text: String
    public let comment: String
    public let commentPrompt: [JSONValue]?
    public let anchor: ChatQuote.Anchor?
    public let attachments: [Attachment]
    public let revision: Double
  }
  public struct State: Codable, Sendable, Equatable {
    public let sessionID: String
    public let revision: Double
    public let quotes: [Quote]
    public let dismissed: [String]
    public init(sessionID: String, revision: Double = 0, quotes: [Quote] = [], dismissed: [String] = []) {
      self.sessionID = sessionID
      self.revision = revision
      self.quotes = quotes
      self.dismissed = dismissed
    }
  }
  /// What clients write: attachments are the IDs `upload` returned, in display order.
  public struct Input: Encodable, Sendable, Equatable {
    public let id: String
    public let messageID: String
    public let partID: String
    public let text: String
    public let comment: String
    public let commentPrompt: [JSONValue]?
    public let anchor: ChatQuote.Anchor?
    public let attachments: [String]
  }
  public struct Saved: Decodable, Sendable { public let revision: Double; public let quote: Quote }
  public struct Imported: Decodable, Sendable {
    public let state: State
    public let imported: [String]
    public let skipped: [String]
  }
  public struct Revision: Decodable, Sendable { public let revision: Double }
  public struct Download: Decodable, Sendable { public let id: String; public let data: String }

  public enum Mode: Sendable, Equatable { case local, server }
  public static let updated = "rpc.custom.quotes.updated"

  /// `info` decides the mode: an unknown RPC keeps local storage; any other failure decides nothing.
  public static func mode(after error: any Error) -> Mode? {
    guard case ClientError.rpc(let type) = error else { return nil }
    return ["rpc.unavailable", "rpc.method_not_found"].contains(type) ? .local : nil
  }
  public static func isAttachmentID(_ id: String) -> Bool {
    id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// A server quote in the draft's shape. Parts that carry bytes are keyed by their attachment ID
  /// (`blob.id`), which is how the draft pairs comment parts with `DraftAttachment`s.
  public static func draft(_ quote: Quote) -> (quote: ChatQuote, attachments: [DraftAttachment]) {
    var value = ChatQuote(id: quote.id, messageID: quote.messageID, partID: quote.partID, text: quote.text,
      comment: quote.comment, anchor: quote.anchor)
    value.commentPrompt = quote.commentPrompt?.map { part in
      guard var object = part.object, let blob = object["blob"]?.object?["id"]?.string, isAttachmentID(blob)
      else { return part }
      object["id"] = .string(blob)
      return .object(object)
    }
    let names = Dictionary((value.commentPrompt ?? []).compactMap { part -> (String, String)? in
      guard let id = part.object?["id"]?.string, let name = part.object?["filename"]?.string else { return nil }
      return (id, name)
    }, uniquingKeysWith: { first, _ in first })
    return (value, quote.attachments.map {
      DraftAttachment(id: $0.id, name: $0.filename ?? names[$0.id] ?? "Anexo", mime: $0.mime, size: $0.size,
        quoteID: quote.id)
    })
  }
  /// Every comment part that carries uploaded bytes references them as `blob: {id, url: ""}`.
  public static func input(_ quote: ChatQuote, attachments: [DraftAttachment]) -> Input {
    let ids = attachments.filter { $0.quoteID == quote.id && isAttachmentID($0.id) }.map(\.id)
    let uploaded = Set(ids)
    let prompt = quote.commentPrompt?.map { part -> JSONValue in
      guard var object = part.object, let id = object["id"]?.string, uploaded.contains(id) else { return part }
      object["blob"] = .object(["id": .string(id), "url": .string("")])
      object.removeValue(forKey: "dataUrl")
      return .object(object)
    }
    return Input(id: quote.id, messageID: quote.messageID, partID: quote.partID, text: quote.text,
      comment: quote.comment, commentPrompt: prompt, anchor: quote.anchor, attachments: ids)
  }
  /// Replaces local attachment IDs with uploaded ones in the quote's comment parts.
  public static func renamed(_ quote: ChatQuote, _ ids: [String: String]) -> ChatQuote {
    var value = quote
    value.commentPrompt = quote.commentPrompt?.map { part in
      guard var object = part.object, let id = object["id"]?.string, let next = ids[id] else { return part }
      object["id"] = .string(next)
      return .object(object)
    }
    return value
  }
}

extension OpenCodeClient {
  private struct SessionInput: Encodable { let sessionID: String }
  public func quotesInfo(directory: String) async throws {
    struct Info: Decodable { let version: Int }
    let _: Info = try await rpc("custom.quotes", "info", input: Empty(), directory: directory)
  }
  public func quotes(_ sessionID: String, directory: String) async throws -> QuoteServer.State {
    try await rpc("custom.quotes", "list", input: SessionInput(sessionID: sessionID), directory: directory)
  }
  public func saveQuote(_ quote: QuoteServer.Input, sessionID: String, directory: String) async throws
    -> QuoteServer.Saved
  {
    struct Input: Encodable { let sessionID: String; let quote: QuoteServer.Input }
    return try await rpc("custom.quotes", "save", input: Input(sessionID: sessionID, quote: quote), directory: directory)
  }
  public func removeQuote(_ id: String, sessionID: String, directory: String) async throws -> Double {
    struct Input: Encodable { let sessionID: String; let id: String }
    let output: QuoteServer.Revision = try await rpc(
      "custom.quotes", "remove", input: Input(sessionID: sessionID, id: id), directory: directory)
    return output.revision
  }
  public func clearQuotes(_ ids: [String], sent: Bool, sessionID: String, directory: String) async throws -> Double {
    struct Input: Encodable { let sessionID: String; let ids: [String]; let reason: String }
    let output: QuoteServer.Revision = try await rpc("custom.quotes", "clear",
      input: Input(sessionID: sessionID, ids: ids, reason: sent ? "sent" : "discarded"), directory: directory)
    return output.revision
  }
  public func importQuotes(_ quotes: [QuoteServer.Input], sessionID: String, directory: String) async throws
    -> QuoteServer.Imported
  {
    struct Input: Encodable { let sessionID: String; let quotes: [QuoteServer.Input] }
    return try await rpc(
      "custom.quotes", "import", input: Input(sessionID: sessionID, quotes: quotes), directory: directory)
  }
  public func dismissQuotes(_ ids: [String], sessionID: String, directory: String) async throws -> Double {
    struct Input: Encodable { let sessionID: String; let ids: [String] }
    let output: QuoteServer.Revision = try await rpc(
      "custom.quotes", "dismiss", input: Input(sessionID: sessionID, ids: ids), directory: directory)
    return output.revision
  }
  public func uploadQuoteAttachment(_ bytes: Data, mime: String, filename: String, sessionID: String,
    directory: String) async throws -> QuoteServer.Attachment
  {
    struct Input: Encodable {
      let sessionID: String
      let mime: String
      let filename: String
      let data: String
    }
    return try await rpc("custom.quotes", "upload",
      input: Input(sessionID: sessionID, mime: mime, filename: String(filename.prefix(255)),
        data: bytes.base64EncodedString()),
      directory: directory, timeout: 300)
  }
  public func quoteAttachment(_ id: String, sessionID: String, directory: String) async throws -> Data {
    struct Input: Encodable { let sessionID: String; let id: String }
    let output: QuoteServer.Download = try await rpc(
      "custom.quotes", "attachment", input: Input(sessionID: sessionID, id: id), directory: directory, timeout: 300)
    guard let data = Data(base64Encoded: output.data) else { throw ClientError.rpc("invalid_data") }
    return data
  }
}

/// One-time move of a Session's local quotes and hidden marks to `custom.quotes`. Idempotent: `import`
/// skips IDs it already has, so a crash before the local copy is deleted only repeats a no-op.
public enum QuoteMigration {
  public enum Outcome: Sendable, Equatable {
    case migrated(QuoteServer.State)
    /// `limit_exceeded`, `session_not_found` or an input the server rejects: keep this Session local.
    case stayLocal
    /// Network or server failure: change nothing and try again later.
    case retryLater
  }
  public static func run(
    quotes: [ChatQuote], attachments: [DraftAttachment], dismissed: [String], sessionID: String,
    directory: String, client: OpenCodeClient, bytes: @Sendable (DraftAttachment) async throws -> Data
  ) async -> Outcome {
    do {
      if !dismissed.isEmpty {
        _ = try await client.dismissQuotes(Array(dismissed.suffix(1000)), sessionID: sessionID, directory: directory)
      }
      guard !quotes.isEmpty else { return .migrated(try await client.quotes(sessionID, directory: directory)) }
      for attempt in 0..<2 {
        let inputs = try await uploaded(quotes, attachments: attachments, sessionID: sessionID,
          directory: directory, client: client, bytes: bytes)
        do {
          return .migrated(try await client.importQuotes(inputs, sessionID: sessionID, directory: directory).state)
        } catch ClientError.rpc("attachment_missing") where attempt == 0 { continue }
      }
      return .retryLater
    } catch ClientError.rpc(let type)
      where ["limit_exceeded", "session_not_found", "rpc.invalid_input", "invalid_data"].contains(type)
    {
      return .stayLocal
    } catch { return .retryLater }
  }
  /// Uploads every local attachment a quote references and returns the quotes in local order with their IDs.
  /// An attachment whose file is gone loses its comment part rather than blocking the move.
  static func uploaded(
    _ quotes: [ChatQuote], attachments: [DraftAttachment], sessionID: String, directory: String,
    client: OpenCodeClient, bytes: @Sendable (DraftAttachment) async throws -> Data
  ) async throws -> [QuoteServer.Input] {
    var renamed: [String: String] = [:]
    var missing: Set<String> = []
    var uploads: [DraftAttachment] = []
    let quoted = Set(quotes.map(\.id))
    for attachment in attachments where attachment.quoteID.map(quoted.contains) == true && attachment.remotePath == nil {
      guard let data = try? await bytes(attachment) else {
        missing.insert(attachment.id)
        continue
      }
      let stored = try await client.uploadQuoteAttachment(
        data, mime: attachment.mime, filename: attachment.name, sessionID: sessionID, directory: directory)
      renamed[attachment.id] = stored.id
      uploads.append(DraftAttachment(id: stored.id, name: attachment.name, mime: stored.mime, size: stored.size,
        quoteID: attachment.quoteID))
    }
    return quotes.map { quote in
      var value = QuoteServer.renamed(quote, renamed)
      value.commentPrompt = value.commentPrompt?.filter { part in
        !(part.object?["id"]?.string.map(missing.contains) ?? false)
      }
      return QuoteServer.input(value, attachments: uploads)
    }
  }
}
