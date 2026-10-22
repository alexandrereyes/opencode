import CryptoKit
import Foundation

public struct DraftSnapshot: Codable, Sendable, Equatable {
  public var document: ComposerDocument
  public var attachments: [DraftAttachment]
  public var model: ModelReference?
  public var agent: String?
  public var cursor: Int
  public var replacing: String?
  public var quotes: [ChatQuote]
  public init(
    document: ComposerDocument = .init(), attachments: [DraftAttachment] = [],
    model: ModelReference? = nil, agent: String? = nil, cursor: Int = 0, replacing: String? = nil,
    quotes: [ChatQuote] = []
  ) {
    self.document = document
    self.attachments = attachments
    self.model = model
    self.agent = agent
    self.cursor = cursor
    self.replacing = replacing
    self.quotes = quotes
  }
  private enum CodingKeys: CodingKey {
    case document, attachments, model, agent, cursor, replacing, quotes
  }
  public init(from decoder: any Decoder) throws {
    let value = try decoder.container(keyedBy: CodingKeys.self)
    document = try value.decode(ComposerDocument.self, forKey: .document)
    attachments = try value.decode([DraftAttachment].self, forKey: .attachments)
    model = try value.decodeIfPresent(ModelReference.self, forKey: .model)
    agent = try value.decodeIfPresent(String.self, forKey: .agent)
    cursor = try value.decode(Int.self, forKey: .cursor)
    replacing = try value.decodeIfPresent(String.self, forKey: .replacing)
    quotes = try value.decodeIfPresent([ChatQuote].self, forKey: .quotes) ?? []
  }
}

public actor DraftPersistence {
  public nonisolated let directory: URL
  public init(server: String, sessionID: String, root: URL? = nil) {
    let root =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpenCode/Drafts", isDirectory: true)
    let key = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
    directory = root.appendingPathComponent(key, isDirectory: true).appendingPathComponent(
      sessionID, isDirectory: true)
  }
  public nonisolated func file(_ attachment: DraftAttachment) -> URL {
    directory.appendingPathComponent(attachment.id)
  }
  public func load() throws -> (DraftSnapshot?, Bool) {
    let url = directory.appendingPathComponent("draft.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return (nil, false) }
    var snapshot = try JSONDecoder().decode(DraftSnapshot.self, from: Data(contentsOf: url))
    var total = 0
    let count = snapshot.attachments.count
    snapshot.attachments = snapshot.attachments.filter { item in
      guard total + item.size <= AttachmentEncoding.draftLimit,
        item.remotePath != nil || FileManager.default.fileExists(atPath: file(item).path)
      else { return false }
      total += item.size
      return true
    }
    if count != snapshot.attachments.count { try save(snapshot) }
    return (snapshot, count != snapshot.attachments.count)
  }
  public func save(_ snapshot: DraftSnapshot) throws {
    try createDirectory()
    try write(JSONEncoder().encode(snapshot), to: directory.appendingPathComponent("draft.json"))
  }
  public func cleanAttachments(retaining attachments: [DraftAttachment]) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    let retained = Set(attachments.map(\.id) + ["draft.json"])
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    where !retained.contains(url.lastPathComponent) {
      try FileManager.default.removeItem(at: url)
    }
  }
  public func store(_ bytes: Data, attachment: DraftAttachment) throws {
    try createDirectory()
    try write(bytes, to: file(attachment))
  }
  public func bytes(_ attachment: DraftAttachment) throws -> Data {
    try Data(contentsOf: file(attachment))
  }
  public func remove() throws {
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }
  public static func pruneMissingSessions(server: String, client: OpenCodeClient) async {
    let root = DraftPersistence(server: server, sessionID: "unused").directory
      .deletingLastPathComponent()
    guard
      let items = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)
    else { return }
    for url in items where url.lastPathComponent.hasPrefix("ses_") {
      do { _ = try await client.session(url.lastPathComponent) } catch ClientError.http(404) {
        try? FileManager.default.removeItem(at: url)
      } catch { continue }
    }
  }
  private func createDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directory.path)
    #endif
  }
  private func write(_ data: Data, to url: URL) throws {
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
}
