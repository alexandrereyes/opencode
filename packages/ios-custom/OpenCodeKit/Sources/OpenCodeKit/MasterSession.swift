import Foundation

public struct MasterSessionInfo: Decodable, Sendable {
  public let version: Int
  public let agent: String
  public let model: ModelReference?
}

public enum MasterAvailability: Sendable, Equatable {
  case loading, available, unsupported, unavailable
  public var label: String {
    switch self {
    case .loading: "Verificando servidor…"
    case .available: ""
    case .unsupported: "Atualize o servidor para usar a Sessão mestra"
    case .unavailable: "Não foi possível verificar a Sessão mestra"
    }
  }
  public static func classify(_ error: any Error) -> Self {
    if case ClientError.rpc(let type) = error,
      ["rpc.unavailable", "rpc.method_not_found"].contains(type) { return .unsupported }
    if case ClientError.http(404) = error { return .unsupported }
    return .unavailable
  }
}

/// The usable master returned by `custom.master/ensure`, which recreates a deleted or archived one.
public struct EnsuredMaster: Decodable, Sendable {
  public let sessionID: String
  public let directory: String
  public let created: Bool
  public let preferences: Preferences
}

public struct ChatAllocation: Codable, Sendable, Equatable {
  public let id: String
  public let directory: String
  public init(id: String, directory: String) {
    self.id = id
    self.directory = directory
  }
}

extension OpenCodeClient {
  public func masterInfo() async throws -> MasterSessionInfo {
    #if DEBUG
    if configuration.url.host == "127.0.0.1", [4179, 4193].contains(configuration.url.port ?? -1),
      ProcessInfo.processInfo.environment["OPENCODE_MASTER_OLD_SERVER"] == "1" {
      throw ClientError.rpc("rpc.unavailable")
    }
    #endif
    return try await rpc("custom.master", "info", input: Empty())
  }
  /// The server serializes this, so the screen, voice and other clients converge on one master.
  /// `model` only applies when a new master has to be created.
  public func ensureMaster(model: ModelReference? = nil) async throws -> EnsuredMaster {
    struct Input: Encodable { let model: ModelReference? }
    return try await rpc("custom.master", "ensure", input: Input(model: model))
  }
  public func allocateChat() async throws -> ChatAllocation {
    try await rpc("custom.chats", "allocate", input: Empty())
  }
  public func claimChat(_ allocation: ChatAllocation, sessionID: String, confirm: Bool = false) async throws {
    struct Input: Encodable { let id: String; let directory: String; let sessionID: String }
    let _: Empty = try await rpc("custom.chats", confirm ? "confirm" : "claim",
      input: Input(id: allocation.id, directory: allocation.directory, sessionID: sessionID))
  }
}

extension ConversationMessage {
  public var masterOrigin: String? {
    guard type == "user" else { return nil }
    return metadata?["custom.master"]?.object?["sessionID"]?.string
  }
}
