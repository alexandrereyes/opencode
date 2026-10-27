import Foundation

public enum SessionDestination: Codable, Sendable, Equatable, Hashable {
  case root, create
  case worktree(String)
  public var key: String {
    switch self {
    case .root: "main"
    case .create: "create"
    case .worktree(let directory): directory
    }
  }
  public var category: String { self == .root ? "local" : "workspace" }
  public func directory(root: String) -> String {
    if case .worktree(let directory) = self { return directory }
    return root
  }
  public static func implicit(setting: String = "last-used", lastUsed: String?) -> Self {
    if setting == "local" { return .root }
    if setting == "new" { return .create }
    return lastUsed == "workspace" ? .create : .root
  }
}

public struct NewSessionContext: Codable, Sendable, Equatable {
  public var projectID: String
  public var destination: SessionDestination
  public var baseBranch: String?
  public var mcp: [String: [String: Bool]]
  /// A managed `custom.chats` destination instead of a project; `projectID` is then unused.
  public var chat: NewSessionChat?
  public init(
    projectID: String, destination: SessionDestination = .root, baseBranch: String? = nil,
    mcp: [String: [String: Bool]] = [:], chat: NewSessionChat? = nil
  ) {
    self.projectID = projectID
    self.destination = destination
    self.baseBranch = baseBranch
    self.mcp = mcp
    self.chat = chat
  }
  public static func chat(mcp: [String: [String: Bool]] = [:]) -> Self {
    .init(projectID: "", mcp: mcp, chat: NewSessionChat())
  }
  public var intentKey: String { chat == nil ? projectID + "\n" + destination.key : "chats" }
  public var intents: [String: Bool] { mcp[intentKey] ?? [:] }
}

/// The Session ID is fixed when Chats is chosen: an allocation claimed for it accepts only that ID on retry.
public struct NewSessionChat: Codable, Sendable, Equatable {
  public var sessionID: String
  public var allocation: ChatAllocation?
  public init(
    sessionID: String = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
    allocation: ChatAllocation? = nil
  ) {
    self.sessionID = sessionID
    self.allocation = allocation
  }
}

public struct WorktreeDirectory: Codable, Sendable, Identifiable, Hashable {
  public let directory: String
  public let strategy: String?
  public var id: String { directory }
  public init(directory: String, strategy: String? = nil) {
    self.directory = directory
    self.strategy = strategy
  }
}
public struct WorktreeBranch: Codable, Sendable {
  public let directory: String
  public let branch: String?
  public init(directory: String, branch: String?) {
    self.directory = directory
    self.branch = branch
  }
}
public struct WorktreeChoice: Sendable, Identifiable, Equatable {
  public let directory: String
  public let label: String
  public var id: String { directory }
}
public struct VCSInfo: Codable, Sendable {
  public let provider: String?
  public let branch: Branch
  public struct Branch: Codable, Sendable {
    public let current: String?
    public let `default`: String?
  }
  public var supportsWorktrees: Bool { provider == "git" || branch.current != nil }
}

/// Where Nova sessão opens. `remember` is false for a Sessões repository-chip preselection, which updates the
/// remembered last project only when the session is sent.
public enum NewSessionStart: Equatable, Sendable {
  case chats
  /// `destination` is nil when the restored draft already targets this project and keeps its own context.
  case project(id: String, destination: SessionDestination?, remember: Bool)
  case none
}

public enum NewSessionProjection {
  /// An originating session wins. Then the Sessões chips: a repository chip preselects that project (its
  /// last-used destination category) and the Chats chip preselects Chats. With "Todas", the Sessões "+" opens
  /// Chats unless the restored draft is project work in progress, a restored chat draft stays a chat, and
  /// otherwise the restored draft, the remembered last project, then the first selected project apply.
  public static func start(
    projects: [Project], origin: NewSessionOrigin?, chatsAvailable: Bool, chatsFilter: Bool,
    filterProjectID: String?, startInChats: Bool, restoredChat: Bool, restoredProjectID: String?,
    restoredWork: Bool, lastProject: String?, categories: [String: String]
  ) -> NewSessionStart {
    let inherited = origin.flatMap { origin in projects.first { $0.id == origin.projectID } }
    let filtered = projects.first { $0.id == filterProjectID }
    if chatsAvailable
      && (origin?.chat == true
        || (inherited == nil
          && ((startInChats && !restoredWork && filtered == nil) || chatsFilter
            || (restoredChat && filtered == nil))))
    {
      return .chats
    }
    if let origin, let inherited {
      return .project(id: inherited.id, destination: origin.destination, remember: true)
    }
    let restored = restoredChat ? nil : projects.first { $0.id == restoredProjectID }
    guard
      let initial = filtered ?? restored
        ?? initialProject(projects, filtered: nil, last: lastProject)
    else { return .none }
    return .project(
      id: initial.id,
      destination: initial.id == restored?.id ? nil : .implicit(lastUsed: categories[initial.id]),
      remember: initial.id != filtered?.id)
  }
  public static func projects(
    _ inventory: [Project], preferences: Preferences?, chatRoot: String?,
    search: String = ""
  ) -> [Project] {
    (preferences?.data.projects["local"]?.projects ?? []).compactMap { entry in
      inventory.first { $0.canonical == entry.worktree || $0.sandboxes.contains(entry.worktree) }
    }.filter {
      $0.canonical != chatRoot
        && (search.isEmpty || $0.displayName.localizedStandardContains(search))
    }
  }
  public static func initialProject(_ projects: [Project], filtered: String?, last: String?)
    -> Project?
  {
    projects.first { $0.id == filtered }
      ?? projects.first { $0.canonical == last || $0.sandboxes.contains(last ?? "") }
      ?? projects.first
  }
  public static func worktrees(
    root: String, inventory: [WorktreeDirectory],
    known: [WorktreeDirectory] = [], sandboxes: [String],
    branches: [WorktreeBranch], home: String? = nil
  ) -> [WorktreeChoice] {
    var seen = Set([URL(fileURLWithPath: root).standardizedFileURL.path])
    let choices = (inventory.map(\.directory) + known.map(\.directory) + sandboxes).filter {
      seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted
    }.map { directory in
      WorktreeChoice(
        directory: directory,
        label: branches.first { $0.directory == directory }?.branch
          ?? URL(fileURLWithPath: directory).lastPathComponent)
    }
    guard let home else { return choices }
    let dev = URL(fileURLWithPath: home).appendingPathComponent("dev").path
    return choices.filter {
      URL(fileURLWithPath: $0.directory).deletingLastPathComponent().path == dev
    }
      + choices.filter {
        URL(fileURLWithPath: $0.directory).deletingLastPathComponent().path != dev
      }
  }
  public static func branches(_ values: [String], current: String?, search: String) -> [String] {
    var seen = Set<String>()
    let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return Array(
      ([current].compactMap { $0 } + values).filter {
        (search.isEmpty || $0.localizedStandardContains(search)) && seen.insert($0).inserted
      }.prefix(50))
  }
  public static func agent(explicit: String?, configured: String?, agents: [AgentInfo]) -> String {
    let choices = agents.filter { $0.hidden != true && $0.mode != "subagent" }
    return [explicit, configured, "build"].compactMap { $0 }.first { id in
      choices.contains { $0.id == id }
    } ?? choices.first?.id ?? "build"
  }
  public static func model(
    explicit: ModelReference?, preferences: Preferences.Models?,
    agent: ModelReference?, configured: ModelReference?,
    recent: [ModelReference], models: [ModelInfo]
  ) -> ModelReference? {
    let saved = preferences?.default.map {
      ModelReference(id: $0.modelID, providerID: $0.providerID, variant: $0.variant)
    }
    let fallback = models.first { $0.enabled != false }.map {
      ModelReference(id: $0.id, providerID: $0.providerID)
    }
    guard
      var selected =
        ([explicit, saved, agent, configured] + recent.map(Optional.some) + [fallback])
        .compactMap({ $0 }).first(where: { candidate in
          models.contains {
            $0.id == candidate.id && $0.providerID == candidate.providerID && $0.enabled != false
          }
        }),
      let info = models.first(where: {
        $0.id == selected.id && $0.providerID == selected.providerID
      })
    else { return nil }
    let same: (ModelReference?) -> Bool = {
      $0?.id == selected.id && $0?.providerID == selected.providerID
    }
    // "default" is the explicit Padrão; a variant the model no longer offers falls through.
    let candidates =
      same(explicit)
      ? [explicit?.variant ?? "default"]
      : [
        same(saved) ? saved?.variant ?? "default" : nil, preferences?.variant[info.identity],
        same(agent) ? agent?.variant : nil, same(configured) ? configured?.variant : nil,
      ]
    let variant = candidates.compactMap { $0 }.first { variant in
      variant == "default" || info.variants?.contains { $0.id == variant } == true
    }
    selected.variant = variant == "default" ? nil : variant
    return selected
  }
  /// The model and effort to keep as the default for new sessions after one is created: a choice
  /// made on this screen, not an origin's inherited model left unchanged, nor one the projection
  /// replaced because it became unavailable.
  public static func remembered(
    explicit: ModelReference?, inherited: ModelReference?, sent: ModelReference,
    saved: Preferences.Models.Key?
  ) -> ModelReference? {
    guard let explicit, explicit != inherited, explicit.id == sent.id,
      explicit.providerID == sent.providerID
    else { return nil }
    let current = saved.map {
      ModelReference(id: $0.modelID, providerID: $0.providerID, variant: $0.variant)
    }
    return current == sent ? nil : sent
  }
}

/// Decode only fields this screen owns; config documents may also contain credentials.
public struct NewSessionConfiguration: Decodable, Sendable {
  public let info: Info
  private enum CodingKeys: CodingKey { case type, info }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decodeIfPresent(String.self, forKey: .type) == "document" else {
      info = Info()
      return
    }
    info = try values.decodeIfPresent(Info.self, forKey: .info) ?? Info()
  }
  public struct Info: Decodable, Sendable {
    public let model: ModelReference?
    public let default_agent: String?
    public let mcp: MCP?
    private enum CodingKeys: CodingKey { case model, default_agent, mcp }
    init() {
      model = nil
      default_agent = nil
      mcp = nil
    }
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      if let text = try? values.decode(String.self, forKey: .model) {
        model = text.firstIndex(of: "/").map { slash in
          ModelReference(
            id: String(text[text.index(after: slash)...]), providerID: String(text[..<slash]))
        }
      } else {
        struct Configured: Decodable {
          let providerID: String
          let model: String
          let variant: String?
        }
        model = try values.decodeIfPresent(Configured.self, forKey: .model).map {
          ModelReference(id: $0.model, providerID: $0.providerID, variant: $0.variant)
        }
      }
      default_agent = try values.decodeIfPresent(String.self, forKey: .default_agent)
      mcp = try values.decodeIfPresent(MCP.self, forKey: .mcp)
    }
    public struct MCP: Decodable, Sendable {
      public let servers: [String: Server]?
      public struct Server: Decodable, Sendable { public let disabled: Bool? }
    }
  }
}

public struct MCPServer: Codable, Sendable, Identifiable, Equatable {
  public let name: String
  public var status: Status
  public let integrationID: String?
  public var id: String { name }
  public struct Status: Codable, Sendable, Equatable {
    public var status: State
    public let error: String?
    public init(_ state: State, error: String? = nil) {
      status = state
      self.error = error
    }
  }
  public enum State: String, Codable, Sendable {
    case connected, disabled, failed
    case needsAuth = "needs_auth"
    case pending, unknown
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
    public var label: String {
      switch self {
      case .connected: "Ativado"
      case .disabled: "Desativado"
      case .failed: "Falhou"
      case .needsAuth: "Precisa de login"
      case .pending: "Conectando"
      case .unknown: "Indisponível"
      }
    }
  }
  public init(name: String, state: State, integrationID: String? = nil) {
    self.name = name
    status = Status(state)
    self.integrationID = integrationID
  }
  public var enabled: Bool { status.status != .disabled && status.status != .unknown }
  public func preview(_ intent: Bool?, defaultEnabled: Bool = true) -> Self {
    var value = self
    value.status = Status((intent ?? defaultEnabled) ? .connected : .disabled)
    return value
  }
  public static func defaults(_ configuration: [NewSessionConfiguration]) -> [String: Bool] {
    var enabled: [String: Bool] = [:]
    for entry in configuration {
      for (name, server) in entry.info.mcp?.servers ?? [:] {
        enabled[name] = server.disabled != true
      }
    }
    return enabled
  }
  public static func ordered(_ servers: [Self]) -> [Self] {
    return servers.sorted {
      let first = $0.status.status == .connected
      let second = $1.status.status == .connected
      if first != second { return first }
      let priority = ["codex-computer-use", "safari-devtools"]
      let a = priority.firstIndex(of: $0.name) ?? priority.count
      let b = priority.firstIndex(of: $1.name) ?? priority.count
      return a != b ? a < b : $0.name < $1.name
    }
  }
  public enum Toggle: Equatable, Sendable { case intent, live, login, unavailable }
  public func toggle(destination: SessionDestination) -> Toggle {
    toggle(preview: destination == .create)
  }
  /// `preview` is a destination that does not exist yet: a new worktree or an unallocated chat.
  public func toggle(preview: Bool) -> Toggle {
    if status.status == .pending || status.status == .unknown { return .unavailable }
    if status.status == .needsAuth { return .login }
    return preview ? .intent : .live
  }
}

extension OpenCodeClient {
  public func worktrees(projectID: String) async throws -> [WorktreeDirectory] {
    try await get("/api/worktree", query: [.init(name: "projectID", value: projectID)])
  }
  /// Like the web's sidebar, prunes checkouts removed outside OpenCode and discovers new ones before listing.
  /// A failed refresh still lists the stored inventory; only the listing itself can fail.
  public func refreshedWorktrees(projectID: String) async throws -> [WorktreeDirectory] {
    struct Input: Encodable { let projectID: String }
    try? await post("/api/worktree/refresh", input: Input(projectID: projectID))
    try Task.checkCancellation()
    return try await worktrees(projectID: projectID)
  }
  public func worktreeBranches(directory: String) async throws -> [WorktreeBranch] {
    try await rpc("custom.worktrees", "branches", input: Empty(), directory: directory)
  }
  public func vcs(directory: String) async throws -> VCSInfo {
    let value: DataResponse<VCSInfo> = try await get(
      "/api/vcs", query: [.init(name: "location[directory]", value: directory)])
    return value.data
  }
  public func baseBranches(directory: String, search: String) async throws -> [String] {
    let value: DataResponse<[String]> = try await get(
      "/api/vcs/branch",
      query: [
        .init(name: "location[directory]", value: directory), .init(name: "search", value: search),
        .init(name: "limit", value: "50"),
      ])
    return value.data
  }
  public func newSessionConfiguration(directory: String) async throws -> [NewSessionConfiguration] {
    try await get("/api/config", query: [.init(name: "location[directory]", value: directory)])
  }
  public func mcpServers(directory: String) async throws -> [MCPServer] {
    let value: DataResponse<[MCPServer]> = try await get(
      "/api/mcp", query: [.init(name: "location[directory]", value: directory)])
    return value.data
  }
  public func toggleMCP(_ name: String, enabled: Bool, directory: String) async throws {
    try await perform(
      "POST", "/api/experimental/mcp/\(name)/\(enabled ? "connect" : "disconnect")",
      query: [.init(name: "location[directory]", value: directory)])
  }
}
