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

public struct ChatAllocation: Codable, Sendable {
  public let id: String
  public let directory: String
}

extension OpenCodeClient {
  public func masterInfo() async throws -> MasterSessionInfo {
    #if DEBUG
    if configuration.url.host == "127.0.0.1", configuration.url.port == 4179,
      ProcessInfo.processInfo.environment["OPENCODE_MASTER_OLD_SERVER"] == "1" {
      throw ClientError.rpc("rpc.unavailable")
    }
    #endif
    return try await rpc("custom.master", "info", input: Empty())
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
