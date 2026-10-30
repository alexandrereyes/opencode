import Foundation

/// Progresso: the agent's own list of steps, the Core `todowrite` tool behind `experimental.todo`
/// (`packages/plugin-app-custom/docs/progress.md`). Every rule copies upstream's web
/// (`packages/app/src/session/composer/todos.ts`, `todo-pill.tsx`, `region.tsx`), like the plugin's
/// `src/progress/todos.ts`.
public struct SessionProgress: Codable, Hashable, Sendable {
  public static let tool = "todowrite"

  public enum Status: String, Codable, Hashable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled
    /// An unknown status reads as pending, like the web.
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
    }
    public var finished: Bool { self == .completed || self == .cancelled }
  }

  public struct Item: Codable, Hashable, Sendable {
    public let content: String
    public let status: Status
    public init(content: String, status: Status) {
      self.content = content
      self.status = status
    }
  }

  public let items: [Item]
  public init(items: [Item]) { self.items = items }

  /// Completed items: the `3` of `3/7`.
  public var done: Int { items.filter { $0.status == .completed }.count }
  /// Completed and cancelled items: the ring's fill.
  public var finished: Int { items.filter(\.status.finished).count }
  /// Every item, cancelled ones included.
  public var total: Int { items.count }
  public var fraction: Double { total > 0 ? Double(finished) / Double(total) : 0 }
  /// The item in hand: the one in progress, else the next pending one, else the last completed one.
  public var current: Item? {
    items.first { $0.status == .inProgress } ?? items.first { $0.status == .pending }
      ?? items.last { $0.status == .completed } ?? items.first
  }
  /// The list still has work left: not empty and not every item completed or cancelled.
  public var open: Bool { !items.isEmpty && !items.allSatisfy(\.status.finished) }
  /// `3/7`.
  public var count: String { "\(done)/\(total)" }

  /// Items with a non-empty `content`; an unknown status reads as pending.
  public static func parse(_ value: JSONValue?) -> [Item] {
    (value?.array ?? []).compactMap { item in
      guard let object = item.object, let content = object["content"]?.string, !content.isEmpty else { return nil }
      return Item(content: content, status: object["status"]?.string.flatMap(Status.init(rawValue:)) ?? .pending)
    }
  }

  /// The list of the latest completed `todowrite` among `messages`, in server order and already cut at the revert
  /// boundary (`SessionRevert.visible`). Nil when none of them has a completed call: the loaded tail may not reach it.
  public static func latest(in messages: [ConversationMessage]) -> [Item]? {
    for message in messages.reversed() where message.type == "assistant" {
      if let part = message.content?.last(where: { $0.type == "tool" && $0.name == tool && $0.status == "completed" }) {
        return parse(part.input["todos"])
      }
    }
    return nil
  }

  /// `experimental.todo`, read like the server: the highest-priority config document that sets `experimental`
  /// decides. Off hides every list, so the plans of migrated V1 sessions never come back.
  public static func enabled(_ configuration: [NewSessionConfiguration]) -> Bool {
    configuration.last { $0.info.experimental != nil }?.info.experimental?.todo == true
  }

  /// A `todowrite` call followed from the event stream, so a list moves before the next snapshot.
  public struct Tracker: Sendable {
    private var names: [String: String] = [:]
    private var calls: [String: [Item]] = [:]
    public init() {}
    /// Folds one event; returns the session and its new list when a `todowrite` call succeeded.
    public mutating func apply(_ event: ConversationEvent) -> (sessionID: String, items: [Item])? {
      guard let call = event.data.id, let session = event.data.sessionID else { return nil }
      switch event.type {
      case "session.tool.input.started":
        if event.data.name == SessionProgress.tool { names[call] = session }
      case "session.tool.called":
        if names[call] == session { calls[call] = parse(event.data.input?.object?["todos"]) }
      case "session.tool.success":
        names[call] = nil
        if let items = calls.removeValue(forKey: call) { return (session, items) }
      case "session.tool.failed":
        names[call] = nil
        calls[call] = nil
      default: break
      }
      return nil
    }
  }
}

public extension NavigationEntry {
  /// The plugin's Progresso of this session while it shows (rev. 2026-10-30); absent on older servers.
  struct Progress: Codable, Sendable, Hashable {
    public let done: Int
    public let finished: Int
    public let total: Int
    public let current: String
    public let todos: [SessionProgress.Item]
  }
}
