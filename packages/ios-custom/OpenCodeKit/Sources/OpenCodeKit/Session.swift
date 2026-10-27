import Foundation

public struct Session: Codable, Sendable, Identifiable, Hashable {
  public let id: String
  public let parentID: String?
  public let projectID: String
  public var title: String?
  public let location: Location
  public let time: Time
  public let outcome: Outcome?
  public let agent: String?
  public let model: ModelReference?
  public let cost: Double?
  public let tokens: TokenUsage?
  public var context: SessionContext?
  public var revert: SessionRevertState?

  public struct Location: Codable, Sendable, Hashable {
    public let directory: String
    public let workspaceID: String?
  }

  public struct Time: Codable, Sendable, Hashable {
    public let created: Double
    public let updated: Double
    public let idle: Double?
    public let viewed: Double?
    public let archived: Double?
  }

  public enum Outcome: String, Codable, Sendable {
    case succeeded, failed, interrupted, unknown
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  public var displayTitle: String { title?.isEmpty == false ? title! : "Sem título" }
  public var key: String { SessionPreferenceKey.encode(id) }
}

public struct NavigationEntry: Codable, Sendable {
  public let session: Session
  public let messageAt: Double?
  public let unreadAt: Double?
  public let permissionAt: Double?
  public let questionAt: Double?
  public let permissionCount: Int?
  public let questionCount: Int?
}

public struct NavigationPage: Codable, Sendable {
  public let data: [NavigationEntry]
  public let next: String?
}

public struct DataResponse<Value: Codable & Sendable>: Codable, Sendable {
  public let data: Value
}

public enum ActiveState: Codable, Sendable {
  case running
  case unknown(String)

  private enum CodingKeys: String, CodingKey { case type }
  public init(from decoder: any Decoder) throws {
    let type = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .type)
    self = type == "running" ? .running : .unknown(type)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .running: try container.encode("running", forKey: .type)
    case .unknown(let type): try container.encode(type, forKey: .type)
    }
  }
  public var isRunning: Bool { if case .running = self { true } else { false } }
}

public struct Project: Codable, Sendable, Identifiable, Hashable {
  public let id: String
  public let canonical: String
  public let name: String?
  public let icon: Icon?
  public let sandboxes: [String]
  public let vcs: String?
  public let worktrees: [WorktreeDirectory]?

  public struct Icon: Codable, Sendable, Hashable {
    public let color: String?
    /// Discovered by the server (a data URL from the repository's favicon), shown only without a chosen color.
    public let url: String?
    /// Chosen through `PATCH /api/project/{id}` (`icon.override`); wins over `url` and `color`.
    public let override: String?
  }
  public var displayName: String {
    name?.isEmpty == false ? name! : URL(fileURLWithPath: canonical).lastPathComponent
  }
}

public struct LocatedDirectory: Codable, Sendable {
  public let directory: String
  public let worktree: String
  public let canonical: String
  public let branch: String?
}
