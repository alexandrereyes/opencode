import CryptoKit
import Foundation

public struct ReadingPosition: Codable, Sendable, Equatable {
  public enum Target: Codable, Sendable, Equatable {
    case followTail
    case message(id: String, offset: Double)
  }
  public var target: Target
  public var updatedAt: Date
  public init(_ target: Target, updatedAt: Date = .now) {
    self.target = target
    self.updatedAt = updatedAt
  }
}

public enum ReadingRestoreDecision: Equatable, Sendable {
  case tail
  case anchor(String, Double)
  case loadOlder, offerResume

  public static func decide(
    _ position: ReadingPosition?, loaded: Set<String>, hasOlder: Bool, pages: Int,
    budget: Int = 5
  ) -> Self {
    guard case .message(let id, let offset) = position?.target else { return .tail }
    if loaded.contains(id) { return .anchor(id, offset) }
    if !hasOlder { return .tail }
    return pages < budget ? .loadOlder : .offerResume
  }
}

public struct ReadingMessageFrame: Sendable {
  public let id: String
  public let top: Double
  public let bottom: Double
  public init(id: String, top: Double, bottom: Double) {
    self.id = id
    self.top = top
    self.bottom = bottom
  }
}

public enum ReadingCapture {
  public static func target(
    followTail: Bool, frames: [ReadingMessageFrame], usableTop: Double, viewportBottom: Double
  ) -> ReadingPosition.Target? {
    if followTail { return .followTail }
    // A gap between rows belongs to the next message; a partially visible row keeps its offset.
    guard
      let frame = frames.filter({ $0.bottom > usableTop && $0.top < viewportBottom })
        .min(by: { $0.top < $1.top })
    else { return nil }
    return .message(id: frame.id, offset: usableTop - frame.top)
  }
  public static func clampedOffset(_ offset: Double, height: Double) -> Double {
    min(max(0, height - 1), max(-32, offset))
  }
}

/// Small metadata only. The server hash is deliberately identical to DraftPersistence's identity.
@MainActor public final class ReadingPositionStore {
  private struct Entry: Codable {
    let sessionID: String
    var position: ReadingPosition
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
      .appendingPathComponent("OpenCode/Reading", isDirectory: true))
      .appendingPathComponent(key + ".json")
    // Bounded metadata is read before mounting the list, so it never flashes at the tail first.
    entries = Array(
      ((try? Data(contentsOf: file)).flatMap {
        try? JSONDecoder().decode([Entry].self, from: $0)
      } ?? []).suffix(self.capacity))
  }
  public func position(_ sessionID: String) -> ReadingPosition? {
    guard let index = entries.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
    let entry = entries.remove(at: index)
    entries.append(entry)
    return entry.position
  }
  public func set(_ position: ReadingPosition, sessionID: String) {
    entries.removeAll { $0.sessionID == sessionID }
    entries.append(Entry(sessionID: sessionID, position: position))
    entries = Array(entries.suffix(capacity))
  }
  public func flush() throws {
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

/// Explicit false values matter: collapsing a running group overrides its default-open state.
@MainActor public final class ConversationExpansionMemory {
  private var sessions: [(id: String, values: [String: Bool])] = []
  private let capacity: Int
  public init(capacity: Int = 16) { self.capacity = max(1, capacity) }
  public func values(_ sessionID: String) -> [String: Bool] {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return [:] }
    let entry = sessions.remove(at: index)
    sessions.append(entry)
    return entry.values
  }
  public func set(_ values: [String: Bool], sessionID: String) {
    sessions.removeAll { $0.id == sessionID }
    sessions.append((sessionID, values))
    sessions = Array(sessions.suffix(capacity))
  }
}
