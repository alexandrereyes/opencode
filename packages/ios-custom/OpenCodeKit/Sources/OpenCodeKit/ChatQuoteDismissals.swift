import CryptoKit
import Foundation

/// Sent quote IDs whose response marks are hidden on this device. `metadata.quotes` stays untouched,
/// so the carrying user bubble keeps its record and source navigation. The server hash matches DraftPersistence.
@MainActor public final class ChatQuoteDismissals {
  private struct Entry: Codable {
    let sessionID: String
    var quotes: Set<String>
  }
  public let file: URL
  private let capacity: Int
  private var entries: [Entry]
  public init(server: String, root: URL? = nil, capacity: Int = 200) {
    self.capacity = max(1, capacity)
    let key = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
    file =
      (root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpenCode/QuoteMarks", isDirectory: true))
      .appendingPathComponent(key + ".json")
    entries = Array(
      ((try? Data(contentsOf: file)).flatMap {
        try? JSONDecoder().decode([Entry].self, from: $0)
      } ?? []).suffix(self.capacity))
  }
  public func values(_ sessionID: String) -> Set<String> {
    entries.first { $0.sessionID == sessionID }?.quotes ?? []
  }
  public func dismiss(_ quotes: Set<String>, sessionID: String) throws {
    guard !quotes.isEmpty else { return }
    let current = values(sessionID)
    entries.removeAll { $0.sessionID == sessionID }
    entries.append(Entry(sessionID: sessionID, quotes: current.union(quotes)))
    entries = Array(entries.suffix(capacity))
    try flush()
  }
  public func remove(_ ids: Set<String>) throws {
    entries.removeAll { ids.contains($0.sessionID) }
    try flush()
  }
  private func flush() throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: file.deletingLastPathComponent().path)
      try JSONEncoder().encode(entries).write(
        to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    #endif
  }
}
