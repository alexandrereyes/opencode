import Foundation

public protocol NewSessionActions: Sendable {
  func createWorktree(projectID: String, from: String, branch: String?) async throws -> String
  func mcpServers(directory: String) async throws -> [MCPServer]
  func toggleMCP(_ name: String, enabled: Bool, directory: String) async throws
  func createSession(id: String, agent: String, model: ModelReference, directory: String)
    async throws
  func prompt(_ request: PromptRequest, sessionID: String) async throws
  func command(_ name: String, request: PromptRequest, sessionID: String) async throws
}

public struct NewSessionFailure: Error, LocalizedError, Sendable {
  public enum Stage: String, Sendable { case worktree, mcp, session, prompt }
  public let stage: Stage
  public let createdDirectory: String?
  public let sessionID: String?
  public let detail: String
  public var errorDescription: String? {
    let message =
      switch stage {
      case .worktree: "Não foi possível criar a worktree."
      case .mcp: "Não foi possível preparar os MCPs."
      case .session: "Não foi possível criar a sessão."
      case .prompt: "A sessão foi criada, mas a mensagem não foi enviada."
      }
    return message + " " + detail
  }
}

public struct NewSessionSubmission: Sendable {
  public let id: String
  public let projectID: String
  public let root: String
  public let destination: SessionDestination
  public let branch: String?
  public let intents: [String: Bool]
  public let agent: String
  public let model: ModelReference
  public let command: String?
  public init(
    id: String = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
    projectID: String, root: String, destination: SessionDestination, branch: String?,
    intents: [String: Bool], agent: String, model: ModelReference, command: String? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.root = root
    self.destination = destination
    self.branch = branch
    self.intents = intents
    self.agent = agent
    self.model = model
    self.command = command
  }
  public func send(
    using client: some NewSessionActions,
    request: @Sendable (String) async throws -> PromptRequest
  ) async throws -> String {
    let directory: String
    do {
      directory =
        destination == .create
        ? try await client.createWorktree(projectID: projectID, from: root, branch: branch)
        : destination.directory(root: root)
    } catch {
      throw NewSessionFailure(
        stage: .worktree, createdDirectory: nil, sessionID: nil, detail: error.localizedDescription)
    }
    let created = destination == .create ? directory : nil
    do { try await prepareMCPs(using: client, directory: directory) } catch {
      throw NewSessionFailure(
        stage: .mcp, createdDirectory: created, sessionID: nil, detail: error.localizedDescription)
    }
    do {
      try await client.createSession(id: id, agent: agent, model: model, directory: directory)
    } catch {
      throw NewSessionFailure(
        stage: .session, createdDirectory: created, sessionID: nil,
        detail: error.localizedDescription)
    }
    do {
      let prompt = try await request(directory)
      if let command { try await client.command(command, request: prompt, sessionID: id) }
      if command == nil { try await client.prompt(prompt, sessionID: id) }
    } catch {
      throw NewSessionFailure(
        stage: .prompt, createdDirectory: created, sessionID: id, detail: error.localizedDescription
      )
    }
    return directory
  }
  private func prepareMCPs(using client: some NewSessionActions, directory: String) async throws {
    guard !intents.isEmpty else { return }
    let servers = try await client.mcpServers(directory: directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (name, enabled) in intents {
        guard let server = servers.first(where: { $0.name == name }) else {
          if !enabled { continue }
          throw MCPPreparationError(name: name)
        }
        if enabled && server.status.status == .needsAuth { throw MCPPreparationError(name: name) }
        if enabled ? server.status.status == .connected : server.status.status == .disabled {
          continue
        }
        group.addTask { try await client.toggleMCP(name, enabled: enabled, directory: directory) }
      }
      try await group.waitForAll()
    }
    let verified = try await client.mcpServers(directory: directory)
    for (name, enabled) in intents {
      let server = verified.first(where: { $0.name == name })
      guard
        enabled
          ? server?.status.status == .connected
          : server == nil || server?.status.status == .disabled
      else { throw MCPPreparationError(name: name) }
    }
  }
}
private struct MCPPreparationError: LocalizedError {
  let name: String
  var errorDescription: String? {
    "\(name) não está pronto. Se precisar de login, entre pelo app web."
  }
}

extension OpenCodeClient: NewSessionActions {
  public func createWorktree(projectID: String, from: String, branch: String?) async throws
    -> String
  {
    struct Input: Encodable {
      let projectID: String
      let from: String
      let branch: String?
    }
    struct Output: Decodable { let directory: String }
    var request = request("/api/worktree")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(
      Input(projectID: projectID, from: from, branch: branch))
    return try JSONDecoder().decode(Output.self, from: await data(request)).directory
  }
  public func createSession(id: String, agent: String, model: ModelReference, directory: String)
    async throws
  {
    struct Location: Encodable { let directory: String }
    struct Input: Encodable {
      let id: String
      let agent: String
      let model: ModelReference
      let location: Location
    }
    try await post(
      "/api/session",
      input: Input(id: id, agent: agent, model: model, location: Location(directory: directory)))
  }
}
