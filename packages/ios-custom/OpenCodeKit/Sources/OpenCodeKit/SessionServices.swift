import Foundation

public enum ConversationNotice: Sendable, Equatable {
  case incompatible
  case missingDirectory(String)

  public static func classify(_ error: any Error, directory: String?) -> Self? {
    guard let error = error as? ClientError else { return nil }
    switch error {
    case .incompatibleServer: return .incompatible
    case .locationNotFound(let path) where path == directory: return .missingDirectory(path)
    default: return nil
    }
  }
}

public struct SessionService: Sendable, Identifiable {
  public enum State: Sendable { case active, disabled, pending, needsAuth, failed, unavailable }
  public let id: String
  public let state: State
  public var label: String {
    switch state {
    case .active: "Ativo"
    case .disabled: "Desativado"
    case .pending: "Conectando"
    case .needsAuth: "Requer autenticação"
    case .failed: "Falhou"
    case .unavailable: "Indisponível"
    }
  }
}

/// A skill loaded into the session, by direct activation, a prompt attachment or a completed `skill` tool call.
public struct LoadedSkill: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct SessionServices: Sendable {
  public var branch: String?
  public var plugins: [SessionService]?
  public var skills: [LoadedSkill]?
  public var changes: [WorkingChange]?
  public init() {}
}

public struct WorkingChange: Codable, Sendable {
  public let file: String
  public let additions: Int
  public let deletions: Int
  public var status: String?
}

extension OpenCodeClient {
  public func rename(_ sessionID: String, title: String) async throws {
    struct Input: Encodable { let title: String }
    try await perform("PATCH", "/api/session/\(sessionID)", body: JSONEncoder().encode(Input(title: title)))
  }
  public func directoryAvailable(_ directory: String) async throws -> Bool {
    struct Input: Encodable { let directory: String }
    return try await rpc("custom.worktrees", "available", input: Input(directory: directory))
  }
  public func sessionServices(sessionID: String, directory: String) async -> SessionServices {
    async let plugins = try? pluginList(directory: directory)
    async let skills = try? loadedSkills(sessionID: sessionID)
    async let changes = try? workingChanges(directory: directory)
    async let branch = try? currentBranch(directory: directory)
    var value = SessionServices()
    value.plugins = await plugins
    value.skills = await skills
    value.changes = await changes
    value.branch = await branch
    return value
  }
  private func currentBranch(directory: String) async throws -> String? {
    struct VCS: Codable, Sendable {
      let branch: Branch
      struct Branch: Codable, Sendable { let current: String? }
    }
    let response: DataResponse<VCS> = try await get("/api/vcs", query: [
      URLQueryItem(name: "location[directory]", value: directory)
    ])
    return response.data.branch.current
  }
  private func workingChanges(directory: String) async throws -> [WorkingChange] {
    let response: DataResponse<[WorkingChange]> = try await get("/api/vcs/diff", query: [
      URLQueryItem(name: "location[directory]", value: directory),
      URLQueryItem(name: "mode", value: "working"),
    ])
    return response.data
  }
  /// Reduced on the server by the custom plugin, so the phone never pages the transcript to find them.
  private func loadedSkills(sessionID: String) async throws -> [LoadedSkill] {
    struct Input: Encodable { let sessionID: String }
    struct Output: Decodable { let data: [LoadedSkill] }
    let output: Output = try await rpc("custom.transcript", "skills", input: Input(sessionID: sessionID))
    return output.data
  }
  private func pluginList(directory: String) async throws -> [SessionService] {
    let response: DataResponse<[JSONValue]> = try await get("/api/plugin", query: [
      URLQueryItem(name: "location[directory]", value: directory)
    ])
    return response.data.compactMap { value -> SessionService? in
      guard let item = value.object else { return nil }
      if item["source"]?.object?["type"]?.string == "builtin" { return nil }
      guard let name = item["name"]?.string ?? item["id"]?.string
        ?? item["source"]?.object?["target"]?.string ?? item["source"]?.object?["path"]?.string
        ?? item["source"]?.object?["type"]?.string else { return nil }
      let state: SessionService.State = switch item["state"]?.object?["status"]?.string {
      case "connected", "active": .active
      case "disabled": .disabled
      case "pending": .pending
      case "needs_auth": .needsAuth
      case "failed": .failed
      default: .unavailable
      }
      return SessionService(id: name, state: state)
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }
}
