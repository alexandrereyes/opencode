import Foundation
import Testing

@testable import OpenCodeKit

private func newDecode<T: Decodable>(_ json: String, _ type: T.Type = T.self) throws -> T {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}
private let newModel = ModelReference(id: "luna", providerID: "proxy", variant: "low")
private func newProjects() throws -> [Project] {
  try newDecode(
    #"[{"id":"a","canonical":"/a","sandboxes":["/a-w"],"name":"Abacato"},{"id":"b","canonical":"/b","sandboxes":[],"name":"Código"},{"id":"chat","canonical":"/chats","sandboxes":[]}]"#
  )
}

@Test func newSessionProjectsKeepSavedOrderSearchAndInitialPriority() throws {
  let prefs: Preferences = try newDecode(
    #"{"revision":1,"data":{"projects":{"local":{"projects":[{"worktree":"/b","expanded":true},{"worktree":"/chats","expanded":true},{"worktree":"/a-w","expanded":true}],"lastProject":"/a-w"}},"pinnedSessions":[],"settings":{"autoApprove":false}}}"#
  )
  let inventory = try newProjects()
  let projects = NewSessionProjection.projects(inventory, preferences: prefs, chatRoot: "/chats")
  #expect(projects.map(\.id) == ["b", "a"])
  #expect(
    NewSessionProjection.projects(inventory, preferences: prefs, chatRoot: "/chats", search: "codi")
      .map(\.id) == ["b"])
  #expect(NewSessionProjection.initialProject(projects, filtered: "b", last: "/a-w")?.id == "b")
  #expect(NewSessionProjection.initialProject(projects, filtered: nil, last: "/a-w")?.id == "a")
  #expect(
    NewSessionProjection.initialProject(projects, filtered: "stale", last: "/missing")?.id == "b")
  #expect(NewSessionProjection.initialProject([], filtered: nil, last: "/a") == nil)
}

@Test func newSessionWorktreesMergeDedupeLabelAndDevPriorityWithoutSorting() {
  let result = NewSessionProjection.worktrees(
    root: "/repo",
    inventory: [
      .init(directory: "/repo/"), .init(directory: "/z"), .init(directory: "/home/dev/b"),
      .init(directory: "/x"),
    ], known: [.init(directory: "/x"), .init(directory: "/y")],
    sandboxes: ["/z", "/home/dev/a", "/other/c"],
    branches: [.init(directory: "/z", branch: "feat/redesign")], home: "/home")
  #expect(result.map(\.directory) == ["/home/dev/b", "/home/dev/a", "/z", "/x", "/y", "/other/c"])
  #expect(result.map(\.label) == ["b", "a", "feat/redesign", "x", "y", "c"])
}

@Test func newSessionLastUsedRemembersCategoryNotPathOrBranch() {
  #expect(SessionDestination.implicit(lastUsed: nil) == .root)
  #expect(SessionDestination.implicit(lastUsed: "local") == .root)
  #expect(
    SessionDestination.implicit(lastUsed: SessionDestination.worktree("/existing").category)
      == .create)
  #expect(SessionDestination.implicit(setting: "local", lastUsed: "workspace") == .root)
  #expect(SessionDestination.implicit(setting: "new", lastUsed: "local") == .create)
  #expect(SessionDestination.create.directory(root: "/root") == "/root")
  #expect(SessionDestination.worktree("/other").directory(root: "/root") == "/other")
}

@Test func newSessionBaseBranchSearchIncludesCurrentDedupeAndLimit() {
  #expect(
    NewSessionProjection.branches(
      ["main", "feat/a", "main", "feat/b"], current: "main", search: "") == [
        "main", "feat/a", "feat/b",
      ])
  #expect(
    NewSessionProjection.branches(["feat/a", "feat/b"], current: "main", search: "FEAT/A") == [
      "feat/a"
    ])
  #expect(
    NewSessionProjection.branches((0..<100).map(String.init), current: "main", search: "").count
      == 50)
}

@Test func newSessionMCPConfigOrderAndFutureStates() throws {
  let config: [NewSessionConfiguration] = try newDecode(
    #"[{"type":"document","info":{"model":"proxy/luna","mcp":{"servers":{"alpha":{"disabled":true},"zeta":{"disabled":false}}}}},{"type":"directory"},{"type":"document","info":{"mcp":{"servers":{"alpha":{"disabled":false},"zeta":{"disabled":true}}}}}]"#
  )
  let servers = [
    MCPServer(name: "zeta", state: .connected), MCPServer(name: "alpha", state: .disabled),
    MCPServer(name: "beta", state: .failed),
  ]
  #expect(
    MCPServer.ordered(servers).map(\.name) == ["zeta", "alpha", "beta"])
  #expect(MCPServer.defaults(config) == ["alpha": true, "zeta": false])
  #expect(config.first?.info.model?.id == "luna")
  let future: MCPServer = try newDecode(#"{"name":"x","status":{"status":"new-status"}}"#)
  #expect(future.status.status == .unknown)
  #expect(future.toggle(destination: .root) == .unavailable)
  for state in [MCPServer.State.connected, .disabled, .failed, .needsAuth, .pending] {
    let decoded: MCPServer = try newDecode(
      "{\"name\":\"x\",\"status\":{\"status\":\"\(state.rawValue)\"}}")
    #expect(decoded.status.status == state)
  }
}

@Test func newSessionMCPToggleSeparatesIntentLiveLoginAndPending() {
  let connected = MCPServer(name: "safe", state: .connected)
  #expect(connected.toggle(destination: .create) == .intent)
  #expect(connected.toggle(destination: .root) == .live)
  #expect(connected.toggle(destination: .worktree("/other")) == .live)
  #expect(connected.preview(false).status.status == .disabled)
  #expect(connected.preview(nil) == connected)
  #expect(
    MCPServer(name: "disabled-root", state: .disabled).preview(nil).status.status == .connected)
  #expect(connected.preview(nil, defaultEnabled: false).status.status == .disabled)
  #expect(MCPServer(name: "failed", state: .failed).enabled)
  #expect(MCPServer(name: "auth", state: .needsAuth).enabled)
  #expect(MCPServer(name: "auth", state: .needsAuth).toggle(destination: .create) == .login)
  #expect(MCPServer(name: "pending", state: .pending).toggle(destination: .root) == .unavailable)
}

@Test func newSessionModelAgentAndEffortPrecedence() throws {
  let models: [ModelInfo] = try newDecode(
    "["
      + ["explicit", "saved", "agent", "configured", "recent", "fallback"].map {
        "{\"id\":\"\($0)\",\"providerID\":\"p\",\"name\":\"\($0)\",\"enabled\":true,\"limit\":{\"context\":1},\"variants\":[{\"id\":\"low\"},{\"id\":\"high\"}]}"
      }.joined(separator: ",") + "]")
  let preference: Preferences.Models = try newDecode(
    #"{"user":[],"variant":{"p/saved":"high"},"default":{"providerID":"p","modelID":"saved","variant":"low"}}"#
  )
  let refs = ["explicit", "agent", "configured", "recent"].map {
    ModelReference(id: $0, providerID: "p", variant: "low")
  }
  func resolve(
    _ explicit: ModelReference?, _ prefs: Preferences.Models?, _ agent: ModelReference?,
    _ configured: ModelReference?, _ recent: [ModelReference]
  ) -> ModelReference? {
    NewSessionProjection.model(
      explicit: explicit, preferences: prefs, agent: agent, configured: configured, recent: recent,
      models: models)
  }
  #expect(resolve(refs[0], preference, refs[1], refs[2], [refs[3]]) == refs[0])
  #expect(resolve(nil, preference, refs[1], refs[2], [refs[3]])?.id == "saved")
  #expect(resolve(nil, preference, refs[1], refs[2], [])?.variant == "low")
  #expect(resolve(nil, nil, refs[1], refs[2], []) == refs[1])
  #expect(resolve(nil, nil, nil, refs[2], []) == refs[2])
  #expect(resolve(nil, nil, nil, nil, [refs[3]])?.id == "recent")
  #expect(resolve(nil, nil, nil, nil, [refs[3]])?.variant == nil)
  #expect(resolve(nil, nil, nil, nil, [])?.id == "explicit")
  #expect(resolve(.init(id: "saved", providerID: "p"), preference, nil, nil, [])?.variant == nil)
  #expect(
    resolve(.init(id: "saved", providerID: "p", variant: "invalid"), preference, nil, nil, [])?
      .variant == nil)
  #expect(
    resolve(.init(id: "explicit", providerID: "wrong"), preference, nil, nil, [])?.id == "saved")
  // A saved default whose effort the model no longer offers falls back to the ordinary effort.
  let lost: Preferences.Models = try newDecode(
    #"{"user":[],"variant":{"p/saved":"high"},"default":{"providerID":"p","modelID":"saved","variant":"gone"}}"#
  )
  #expect(resolve(nil, lost, nil, nil, []) == .init(id: "saved", providerID: "p", variant: "high"))
  let padrao: Preferences.Models = try newDecode(
    #"{"user":[],"variant":{"p/saved":"high"},"default":{"providerID":"p","modelID":"saved"}}"#
  )
  #expect(resolve(nil, padrao, nil, nil, [])?.variant == nil)
  // A saved default that is no longer available falls back to the previous precedence.
  let missing: Preferences.Models = try newDecode(
    #"{"user":[],"variant":{},"default":{"providerID":"p","modelID":"removed","variant":"low"}}"#
  )
  #expect(resolve(nil, missing, refs[1], refs[2], []) == refs[1])
  let agents: [AgentInfo] = try newDecode(
    #"[{"id":"hidden","name":"Hidden","mode":"primary","hidden":true},{"id":"child","name":"Child","mode":"subagent"},{"id":"build","name":"Build","mode":"primary"},{"id":"plan","name":"Plan","mode":"all"}]"#
  )
  #expect(
    NewSessionProjection.agent(explicit: "hidden", configured: "child", agents: agents) == "build")
  #expect(
    NewSessionProjection.agent(explicit: "plan", configured: "build", agents: agents) == "plan")
  #expect(NewSessionProjection.agent(explicit: nil, configured: "plan", agents: agents) == "plan")
}

@Test func newSessionRemembersOnlyADeliberateChoice() {
  let chosen = ModelReference(id: "luna", providerID: "p", variant: "low")
  let saved = Preferences.Models.Key(providerID: "p", modelID: "sol", variant: "high")
  func remembered(_ explicit: ModelReference?, inherited: ModelReference? = nil,
    sent: ModelReference = chosen, saved: Preferences.Models.Key? = saved) -> ModelReference? {
    NewSessionProjection.remembered(explicit: explicit, inherited: inherited, sent: sent, saved: saved)
  }
  #expect(remembered(chosen) == chosen)
  #expect(remembered(chosen, saved: nil) == chosen)
  // Padrão is a deliberate effort too.
  let padrao = ModelReference(id: "luna", providerID: "p")
  #expect(remembered(padrao, sent: padrao) == padrao)
  // Nothing chosen on the screen: the projection's own pick is not a new default.
  #expect(remembered(nil) == nil)
  // Inherited from the originating conversation and left unchanged.
  #expect(remembered(chosen, inherited: chosen) == nil)
  #expect(remembered(chosen, inherited: .init(id: "luna", providerID: "p", variant: "high")) == chosen)
  // Already the default.
  #expect(remembered(chosen, saved: .init(providerID: "p", modelID: "luna", variant: "low")) == nil)
  // The chosen model became unavailable, so another one was sent.
  #expect(remembered(chosen, sent: .init(id: "sol", providerID: "p")) == nil)
  // The effort is normalized to what was sent.
  #expect(remembered(.init(id: "luna", providerID: "p", variant: "gone"), sent: padrao) == padrao)
}

private actor NewSessionFake: NewSessionActions {
  var calls: [String] = []
  var servers: [MCPServer]
  let failure: String?
  init(failure: String? = nil, state: MCPServer.State = .connected) {
    self.failure = failure
    servers = [MCPServer(name: "safe", state: state)]
  }
  private func record(_ call: String) throws {
    calls.append(call)
    if failure == call { throw ClientError.http(400) }
  }
  func createWorktree(projectID: String, from: String, branch: String?) throws -> String {
    try record("worktree")
    #expect(projectID == "project" && from == "/root" && branch == "base")
    return "/created"
  }
  func allocateChat() throws -> ChatAllocation {
    try record("allocate")
    return ChatAllocation(id: "allocation", directory: "/chats/day/session-a")
  }
  func claimChat(_ allocation: ChatAllocation, sessionID: String, confirm: Bool) throws {
    try record(confirm ? "confirm" : "claim")
    #expect(allocation.id == "allocation" && sessionID == "ses_client")
  }
  var directories: Set<String> = []
  func mcpServers(directory: String) throws -> [MCPServer] {
    directories.insert(directory)
    try record(calls.contains("list") ? "verify" : "list")
    return servers
  }
  func toggleMCP(_ name: String, enabled: Bool, directory: String) throws {
    try record("toggle")
    if failure != "verification" {
      servers = [.init(name: name, state: enabled ? .connected : .disabled)]
    }
  }
  func createSession(id: String, agent: String, model: ModelReference, directory: String) throws {
    directories.insert(directory)
    try record("session")
    #expect(id == "ses_client" && agent == "build" && model == newModel)
  }
  func prompt(_ request: PromptRequest, sessionID: String) throws { try record("prompt") }
  func command(_ name: String, request: PromptRequest, sessionID: String) throws {
    try record("command")
  }
}
private func newSubmission(
  destination: SessionDestination = .create, intents: [String: Bool] = ["safe": false],
  command: String? = nil
) -> NewSessionSubmission {
  .init(
    id: "ses_client", projectID: "project", root: "/root", destination: destination, branch: "base",
    intents: intents,
    agent: "build", model: newModel, command: command)
}
private func newRequest(_ directory: String) -> PromptRequest {
  .init(text: "OK", delivery: .steer, agent: "build", model: newModel)
}

@Test func newSessionTypedBackendCommandUsesSameSerializationAndLocalCommandsStayDisabled() throws {
  var sources = ComposerSources()
  sources.commands = try newDecode(#"[{"name":"review"}]"#)
  let document = sources.newSessionDocument(.init(text: "/review confira"))
  #expect(ComposerDispatch.resolve(document) == .command("review", "confira"))
  #expect(
    PromptRequest(document: document, delivery: .steer, agent: "build", model: newModel).text
      == "confira")
  #expect(
    ComposerDispatch.resolve(sources.newSessionDocument(.init(text: "/compact")))
      == .local("compact"))
  #expect(ComposerDispatch.resolve(sources.newSessionDocument(.init(text: "/unknown"))) == .prompt)
  let skill = ComposerDocument(
    text: "/review",
    tokens: [.init(start: 0, end: 7, token: .init(kind: .skill, id: "review", text: "/review"))])
  #expect(sources.newSessionDocument(skill) == skill)
}

@Test func newSessionSendCreatesThenPreparesVerifiesCreatesSessionThenPrompts() async throws {
  let fake = NewSessionFake()
  #expect(try await newSubmission().send(using: fake, request: newRequest) == "/created")
  #expect(await fake.calls == ["worktree", "list", "toggle", "verify", "session", "prompt"])
}
@Test func newSessionRootAndExistingSkipCreationAndUnrequestedMCPsDoNotBlock() async throws {
  for destination in [SessionDestination.root, .worktree("/existing")] {
    let fake = NewSessionFake()
    let directory = try await newSubmission(destination: destination, intents: [:]).send(
      using: fake, request: newRequest)
    #expect(directory == destination.directory(root: "/root"))
    #expect(await fake.calls == ["session", "prompt"])
  }
}
@Test func newSessionBackendCommandRunsOnlyAfterSessionCreation() async throws {
  let fake = NewSessionFake()
  _ = try await newSubmission(destination: .root, intents: [:], command: "review").send(
    using: fake, request: newRequest)
  #expect(await fake.calls == ["session", "command"])
}
@Test(arguments: ["worktree", "list", "toggle", "verify", "verification", "session", "prompt"])
func newSessionPipelineFailurePreservesCreatedDirectoryAndExistingSession(_ point: String)
  async throws
{
  let fake = NewSessionFake(failure: point)
  do {
    _ = try await newSubmission().send(using: fake, request: newRequest)
    Issue.record("Expected failure")
  } catch let error as NewSessionFailure {
    let expected: NewSessionFailure.Stage =
      point == "worktree"
      ? .worktree : point == "session" ? .session : point == "prompt" ? .prompt : .mcp
    #expect(error.stage == expected)
    #expect(error.createdDirectory == (point == "worktree" ? nil : "/created"))
    #expect(error.sessionID == (point == "prompt" ? "ses_client" : nil))
    let calls = await fake.calls
    if expected == .mcp { #expect(!calls.contains("session")) }
    if expected == .session { #expect(!calls.contains("prompt")) }
  }
}
@Test func newSessionMissingMCPAndPromptPreparationFailureAreNotAtomicSuccess() async throws {
  let fake = NewSessionFake()
  do {
    _ = try await newSubmission(intents: ["missing": true]).send(using: fake, request: newRequest)
    Issue.record("Expected missing MCP failure")
  } catch let error as NewSessionFailure { #expect(error.stage == .mcp) }
  do {
    _ = try await newSubmission(destination: .root, intents: [:]).send(using: NewSessionFake()) {
      _ in throw ClientError.http(400)
    }
    Issue.record("Expected attachment preparation failure")
  } catch let error as NewSessionFailure {
    #expect(error.stage == .prompt && error.sessionID == "ses_client")
  }
}

@Test func newSessionMCPPreparationAllowsAbsentDisabledIntentButNeverStartsOAuth() async throws {
  let absent = NewSessionFake()
  _ = try await newSubmission(destination: .root, intents: ["missing": false]).send(
    using: absent, request: newRequest)
  #expect(await absent.calls == ["list", "verify", "session", "prompt"])
  let auth = NewSessionFake(state: .needsAuth)
  do {
    _ = try await newSubmission(intents: ["safe": true]).send(using: auth, request: newRequest)
    Issue.record("Expected web login requirement")
  } catch let error as NewSessionFailure {
    #expect(error.stage == .mcp && error.createdDirectory == "/created")
    #expect(await auth.calls == ["worktree", "list"])
    #expect(error.localizedDescription.contains("app web"))
  }
  let disabled = NewSessionFake(state: .disabled)
  _ = try await newSubmission(destination: .root).send(using: disabled, request: newRequest)
  #expect(await disabled.calls == ["list", "verify", "session", "prompt"])
}

@Test func newSessionCommandFailureKeepsTheAlreadyCreatedSession() async throws {
  let fake = NewSessionFake(failure: "command")
  do {
    _ = try await newSubmission(destination: .root, intents: [:], command: "review").send(
      using: fake, request: newRequest)
    Issue.record("Expected command failure")
  } catch let error as NewSessionFailure {
    #expect(error.stage == .prompt && error.sessionID == "ses_client")
    #expect(await fake.calls == ["session", "command"])
  }
}

@Test func newSessionProjectTouchAndDefaultVariantIntentsMatchRPC() throws {
  let touch = try JSONDecoder().decode(
    JSONValue.self, from: JSONEncoder().encode(PreferenceIntent.touch(directory: "/repo")))
  #expect(
    touch
      == .object([
        "type": .string("project.touch"), "server": .string("local"), "directory": .string("/repo"),
      ]))
  let variant = try JSONDecoder().decode(
    JSONValue.self,
    from: JSONEncoder().encode(
      PreferenceIntent.modelVariant(.init(id: "luna", providerID: "proxy"))))
  #expect(variant.object?["variant"] == .string("default"))
}

private actor NewSessionHTTP {
  var requests: [URLRequest] = []
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    requests.append(request)
    let url = request.url!
    let json =
      switch url.path {
      case "/api/vcs/branch": #"{"data":["main"]}"#
      case "/api/worktree": request.httpMethod == "POST" ? #"{"directory":"/new"}"# : "[]"
      case "/api/mcp": #"{"data":[]}"#
      default: "{}"
      }
    return (
      Data(json.utf8),
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}
@Test func newSessionHTTPUsesExactLocationBranchCreateAndToggleContracts() async throws {
  let recorder = NewSessionHTTP()
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://localhost:4177")!)) {
    try await recorder.respond($0)
  }
  _ = try await client.baseBranches(directory: "/repo with space", search: "feat/a & b")
  _ = try await client.createWorktree(projectID: "p", from: "/repo", branch: "base")
  try await client.createSession(id: "ses_c", agent: "build", model: newModel, directory: "/new")
  try await client.toggleMCP("safe", enabled: false, directory: "/new")
  let requests = await recorder.requests
  let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
  #expect(
    query == [
      .init(name: "location[directory]", value: "/repo with space"),
      .init(name: "search", value: "feat/a & b"), .init(name: "limit", value: "50"),
    ])
  let body = try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!)
  #expect(
    body
      == .object(["projectID": .string("p"), "from": .string("/repo"), "branch": .string("base")]))
  let session = try JSONDecoder().decode(JSONValue.self, from: requests[2].httpBody!)
  #expect(session.object?["id"] == .string("ses_c"))
  #expect(session.object?["location"] == .object(["directory": .string("/new")]))
  #expect(requests[3].url?.path == "/api/experimental/mcp/safe/disconnect")
  #expect(requests[3].httpMethod == "POST" && requests[3].httpBody == nil)
}

private actor WorktreeInventoryHTTP {
  let refreshStatus: Int
  let listStatus: Int
  var requests: [String] = []
  var refreshed = false
  init(refreshStatus: Int, listStatus: Int = 200) {
    self.refreshStatus = refreshStatus
    self.listStatus = listStatus
  }
  func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
    let url = request.url!
    requests.append((request.httpMethod ?? "GET") + " " + url.path)
    if url.path == "/api/worktree/refresh" && refreshStatus == 204 { refreshed = true }
    let status = url.path == "/api/worktree/refresh" ? refreshStatus : listStatus
    // Stored inventory keeps checkouts removed outside OpenCode until a refresh prunes them.
    let json =
      url.path == "/api/worktree" && status == 200
      ? refreshed
        ? #"[{"directory":"/w/detached","strategy":"git"},{"directory":"/repo","strategy":"git"}]"#
        : #"[{"directory":"/w/gone","strategy":"git"},{"directory":"/w/detached","strategy":"git"}]"#
      : #"{"_tag":"Error"}"#
    return (
      Data(json.utf8),
      HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}

@Test func newSessionWorktreesAreRefreshedBeforeListingAndKeepDetachedCheckouts() async throws {
  let http = WorktreeInventoryHTTP(refreshStatus: 204)
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://localhost:4177")!)) {
    try await http.respond($0)
  }
  let listed = try await client.refreshedWorktrees(projectID: "p")
  #expect(await http.requests == ["POST /api/worktree/refresh", "GET /api/worktree"])
  // A detached HEAD has no branch in `custom.worktrees/branches`; it is labeled by its folder.
  let branches = try newDecode(
    #"[{"directory":"/repo","branch":"custom"},{"directory":"/w/detached"}]"#,
    [WorktreeBranch].self)
  let choices = NewSessionProjection.worktrees(
    root: "/repo", inventory: listed, sandboxes: [], branches: branches)
  #expect(choices == [WorktreeChoice(directory: "/w/detached", label: "detached")])

  let stale = WorktreeInventoryHTTP(refreshStatus: 500)
  let fallback = OpenCodeClient(configuration: .init(url: URL(string: "http://localhost:4177")!)) {
    try await stale.respond($0)
  }
  #expect(try await fallback.refreshedWorktrees(projectID: "p").map(\.directory) == ["/w/gone", "/w/detached"])

  let broken = WorktreeInventoryHTTP(refreshStatus: 204, listStatus: 500)
  let failing = OpenCodeClient(configuration: .init(url: URL(string: "http://localhost:4177")!)) {
    try await broken.respond($0)
  }
  await #expect(throws: (any Error).self) { try await failing.refreshedWorktrees(projectID: "p") }
}

@Test func newSessionDraftRoundTripContainsDestinationPreviewTokensAndAttachments() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let persistence = DraftPersistence(server: "sandbox", sessionID: "new-session", root: root)
  let attachment = DraftAttachment(name: "a.txt", mime: "text/plain", size: 2)
  try await persistence.store(Data("OK".utf8), attachment: attachment)
  let token = ComposerToken(kind: .file, id: "a", text: "@a", value: "/a")
  let snapshot = DraftSnapshot(
    document: .init(text: "@a", tokens: [.init(start: 0, end: 2, token: token)]),
    attachments: [attachment], model: newModel, agent: "build", cursor: 2,
    newSession: .init(
      projectID: "project", destination: .create, baseBranch: "base",
      mcp: ["project\ncreate": ["safe": false]]))
  try await persistence.save(snapshot)
  #expect(try await persistence.load().0 == snapshot)
  #expect(try await persistence.load().0?.newSession?.intents == ["safe": false])
  let other = DraftPersistence(server: "other", sessionID: "new-session", root: root)
  #expect(try await other.load().0 == nil)
}

private func chatSubmission(
  allocation: ChatAllocation? = nil, intents: [String: Bool] = [:]
) -> NewSessionSubmission {
  .init(
    chat: .init(sessionID: "ses_client", allocation: allocation), intents: intents,
    agent: "build", model: newModel)
}

@Test func newSessionChatAllocatesClaimsCreatesConfirmsThenPrompts() async throws {
  let fake = NewSessionFake()
  let directory = try await chatSubmission(intents: ["safe": false]).send(
    using: fake, request: newRequest)
  #expect(directory == "/chats/day/session-a")
  #expect(
    await fake.calls == ["allocate", "claim", "list", "toggle", "verify", "session", "confirm", "prompt"])
  #expect(await fake.directories == ["/chats/day/session-a"])
}

@Test func newSessionChatRetryReusesItsAllocationAndIgnoresConfirmFailure() async throws {
  let allocation = ChatAllocation(id: "allocation", directory: "/chats/day/session-a")
  let fake = NewSessionFake(failure: "confirm")
  _ = try await chatSubmission(allocation: allocation).send(using: fake, request: newRequest)
  #expect(await fake.calls == ["claim", "session", "confirm", "prompt"])
}

@Test(arguments: ["allocate", "claim", "list", "session", "prompt"])
func newSessionChatFailureKeepsTheAllocationForRetry(_ point: String) async throws {
  let fake = NewSessionFake(failure: point)
  do {
    _ = try await chatSubmission(intents: ["safe": false]).send(using: fake, request: newRequest)
    Issue.record("Expected failure")
  } catch let error as NewSessionFailure {
    let expected: NewSessionFailure.Stage =
      point == "allocate" || point == "claim"
      ? .chat : point == "list" ? .mcp : point == "session" ? .session : .prompt
    #expect(error.stage == expected)
    #expect(error.createdDirectory == nil)
    #expect(error.allocation?.directory == (point == "allocate" || point == "prompt" ? nil : "/chats/day/session-a"))
    #expect(error.sessionID == (point == "prompt" ? "ses_client" : nil))
    if expected == .chat { #expect(!(await fake.calls).contains("session")) }
  }
}

@Test func newSessionChatContextKeepsSeparateIntentsAndDecodesOldDrafts() throws {
  var chat = NewSessionContext.chat(mcp: ["project\nmain": ["safe": true]])
  chat.mcp[chat.intentKey] = ["safe": false]
  #expect(chat.intentKey == "chats" && chat.intents == ["safe": false])
  #expect(chat.chat?.sessionID.hasPrefix("ses_") == true && chat.chat?.allocation == nil)
  let round = try JSONDecoder().decode(NewSessionContext.self, from: JSONEncoder().encode(chat))
  #expect(round == chat)
  let old: NewSessionContext = try newDecode(
    #"{"projectID":"project","destination":{"root":{}},"mcp":{}}"#)
  #expect(old.chat == nil && old.intentKey == "project\nmain")
  #expect(MCPServer(name: "safe", state: .connected).toggle(preview: true) == .intent)
  #expect(MCPServer(name: "safe", state: .connected).toggle(preview: false) == .live)
}
