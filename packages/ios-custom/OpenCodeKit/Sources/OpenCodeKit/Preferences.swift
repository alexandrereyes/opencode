import Foundation

public enum SessionPreferenceKey {
  // The Mac web app's server key keeps newly pinned and muted sessions shared with it.
  public static let server = "http://localhost:4096"

  public static func encode(_ sessionID: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try! encoder.encode([server, sessionID]), as: UTF8.self)
  }

  public static func sessionID(_ key: String) -> String? {
    if key.hasPrefix("ses") { return key }
    guard let pair = try? JSONDecoder().decode([String].self, from: Data(key.utf8)), pair.count == 2
    else {
      return nil
    }
    return pair[1]
  }

  public static func matching(_ sessionID: String, in keys: [String]) -> [String] {
    keys.filter { self.sessionID($0) == sessionID }
  }
}

public struct Preferences: Codable, Sendable {
  public let revision: Int
  public let data: Data

  public struct Data: Codable, Sendable {
    public let projects: [String: Library]
    public let pinnedSessions: [String]
    public let mutedSessions: [String]?
    public let settings: Settings
  }
  public struct Library: Codable, Sendable {
    public let projects: [Selection]
  }
  public struct Selection: Codable, Sendable {
    public let worktree: String
    public let expanded: Bool
  }
  public struct Settings: Codable, Sendable {
    public let autoApprove: Bool
  }
}

public enum PreferenceIntent: Encodable, Sendable {
  case pin(session: String, pinned: Bool)
  case mute(session: String, muted: Bool)
  case open(directory: String)
  case close(directory: String)
  case move(directory: String, toIndex: Int)

  private enum CodingKeys: String, CodingKey {
    case type, session, pinned, muted, server, directory, toIndex
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pin(let session, let pinned):
      try values.encode("sidebar.pin", forKey: .type)
      try values.encode(session, forKey: .session)
      try values.encode(pinned, forKey: .pinned)
    case .mute(let session, let muted):
      try values.encode("sidebar.mute", forKey: .type)
      try values.encode(session, forKey: .session)
      try values.encode(muted, forKey: .muted)
    case .open(let directory), .close(let directory), .move(let directory, _):
      try values.encode("local", forKey: .server)
      try values.encode(directory, forKey: .directory)
      switch self {
      case .open: try values.encode("project.open", forKey: .type)
      case .close: try values.encode("project.close", forKey: .type)
      case .move(_, let index):
        try values.encode("project.move", forKey: .type)
        try values.encode(index, forKey: .toIndex)
      default: break
      }
    }
  }
}
