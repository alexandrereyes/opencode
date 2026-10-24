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
  public enum State: Sendable { case active, disabled, pending, needsAuth, failed, configured, unavailable }
  public let id: String
  public let state: State
  public var label: String {
    switch state {
    case .active: "Ativo"
    case .disabled: "Desativado"
    case .pending: "Conectando"
    case .needsAuth: "Requer autenticação"
    case .failed: "Falhou"
    case .configured: "Configurado"
    case .unavailable: "Indisponível"
    }
  }
}

public struct SessionServices: Sendable {
  public var branch: String?
  public var mcp: [SessionService]?
  public var plugins: [SessionService]?
  public var skills: [SessionService]?
  public var lsp: [SessionService]?
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
  public func sessionServices(directory: String) async -> SessionServices {
    async let mcp = try? serviceList("mcp", directory: directory)
    async let plugins = try? serviceList("plugin", directory: directory)
    async let skills = try? serviceList("skill", directory: directory)
    async let lsp = try? lspConfiguration(directory: directory)
    async let changes = try? workingChanges(directory: directory)
    async let branch = try? currentBranch(directory: directory)
    var value = SessionServices()
    value.mcp = await mcp
    value.plugins = await plugins
    value.skills = await skills
    value.lsp = await lsp
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
  private func serviceList(_ kind: String, directory: String) async throws -> [SessionService] {
    let response: DataResponse<[JSONValue]> = try await get("/api/\(kind)", query: [
      URLQueryItem(name: "location[directory]", value: directory)
    ])
    return response.data.compactMap { value -> SessionService? in
      guard let item = value.object else { return nil }
      if kind == "plugin", item["source"]?.object?["type"]?.string == "builtin" { return nil }
      guard let name = item["name"]?.string ?? item["id"]?.string
        ?? item["source"]?.object?["target"]?.string ?? item["source"]?.object?["path"]?.string
        ?? item["source"]?.object?["type"]?.string else { return nil }
      let status = (kind == "plugin" ? item["state"] : item["status"])?.object?["status"]?.string
      let state: SessionService.State = switch status {
      case "connected", "active": .active
      case "disabled": .disabled
      case "pending": .pending
      case "needs_auth": .needsAuth
      case "failed": .failed
      default: kind == "skill" ? .active : .unavailable
      }
      return SessionService(id: name, state: state)
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }
  private func lspConfiguration(directory: String) async throws -> [SessionService] {
    let values: [JSONValue] = try await get("/api/config", query: [
      URLQueryItem(name: "location[directory]", value: directory)
    ])
    var disabled = false
    var servers: [String: Bool] = [:]
    for value in values {
      guard let lsp = value.object?["info"]?.object?["lsp"] else { continue }
      if let flag = lsp.bool {
        disabled = !flag
        servers.removeAll()
      }
      if let entries = lsp.object {
        disabled = false
        for (name, config) in entries {
          servers[name] = config.object?["disabled"]?.bool ?? servers[name] ?? false
        }
      }
    }
    if disabled { return [SessionService(id: "LSP", state: .disabled)] }
    return servers.sorted { $0.key < $1.key }.map {
      SessionService(id: $0.key, state: $0.value ? .disabled : .configured)
    }
  }
}
