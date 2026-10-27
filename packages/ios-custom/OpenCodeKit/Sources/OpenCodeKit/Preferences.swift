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
    public let masterSessions: [String: String]?
    public let settings: Settings
    public let models: Models?
  }
  public struct Library: Codable, Sendable {
    public let projects: [Selection]
    public let lastProject: String?
    /// How many `projects` precede the Chats filter chip; absent (older servers too) means Chats first.
    public let chatsIndex: Int?
  }
  public struct Selection: Codable, Sendable {
    public let worktree: String
    public let expanded: Bool
  }
  public struct Settings: Codable, Sendable {
    public let autoApprove: Bool
    public let followUpBehavior: PromptDelivery?
  }
  public struct Models: Codable, Sendable {
    public let user: [User]
    public let variant: [String: String]
    public let favorites: [Key]?
    public let providerOrder: [String]?
    public let `default`: Key?
    public struct Key: Codable, Sendable {
      public let providerID: String
      public let modelID: String
      public let variant: String?
    }
    public struct User: Codable, Sendable {
      public let providerID: String
      public let modelID: String
      public let visibility: String
      public let favorite: Bool?
    }
  }
}

public enum PreferenceIntent: Encodable, Sendable {
  case masterSet(String)
  case masterClear
  case pin(session: String, pinned: Bool)
  case mute(session: String, muted: Bool)
  case open(directory: String)
  case touch(directory: String)
  case close(directory: String)
  case move(directory: String, toIndex: Int)
  case chatsMove(toIndex: Int)
  case modelFavorite(providerID: String, modelID: String, favorite: Bool)
  case modelVisibility(providerID: String, modelID: String, visible: Bool)
  case modelDefault(ModelReference?)
  case modelVariant(ModelReference)

  private enum CodingKeys: String, CodingKey {
    case type, session, pinned, muted, server, directory, toIndex, providerID, modelID, favorite,
      visibility, model, variant, sessionID
  }
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .masterSet(let id):
      try values.encode("master.set", forKey: .type)
      try values.encode("local", forKey: .server)
      try values.encode(id, forKey: .sessionID)
    case .masterClear:
      try values.encode("master.clear", forKey: .type)
      try values.encode("local", forKey: .server)
    case .modelVariant(let model):
      try values.encode("model.variant", forKey: .type)
      try values.encode(model.providerID, forKey: .providerID)
      try values.encode(model.id, forKey: .modelID)
      try values.encode(model.variant ?? "default", forKey: .variant)
    case .modelFavorite(let providerID, let modelID, let favorite):
      try values.encode("model.favorite", forKey: .type)
      try values.encode(providerID, forKey: .providerID)
      try values.encode(modelID, forKey: .modelID)
      try values.encode(favorite, forKey: .favorite)
    case .modelVisibility(let providerID, let modelID, let visible):
      try values.encode("model.visibility", forKey: .type)
      try values.encode(providerID, forKey: .providerID)
      try values.encode(modelID, forKey: .modelID)
      try values.encode(visible ? "show" : "hide", forKey: .visibility)
    case .modelDefault(let model):
      try values.encode("model.default", forKey: .type)
      if let model {
        try values.encode(
          Preferences.Models.Key(
            providerID: model.providerID, modelID: model.id,
            variant: model.variant), forKey: .model)
      } else {
        try values.encodeNil(forKey: .model)
      }
    case .pin(let session, let pinned):
      try values.encode("sidebar.pin", forKey: .type)
      try values.encode(session, forKey: .session)
      try values.encode(pinned, forKey: .pinned)
    case .mute(let session, let muted):
      try values.encode("sidebar.mute", forKey: .type)
      try values.encode(session, forKey: .session)
      try values.encode(muted, forKey: .muted)
    case .chatsMove(let index):
      try values.encode("chats.move", forKey: .type)
      try values.encode("local", forKey: .server)
      try values.encode(index, forKey: .toIndex)
    case .open(let directory), .touch(let directory), .close(let directory), .move(let directory, _):
      try values.encode("local", forKey: .server)
      try values.encode(directory, forKey: .directory)
      switch self {
      case .open: try values.encode("project.open", forKey: .type)
      case .touch: try values.encode("project.touch", forKey: .type)
      case .close: try values.encode("project.close", forKey: .type)
      case .move(_, let index):
        try values.encode("project.move", forKey: .type)
        try values.encode(index, forKey: .toIndex)
      default: break
      }
    }
  }
}
