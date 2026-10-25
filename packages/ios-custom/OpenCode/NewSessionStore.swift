import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class NewSessionStore {
  let sessions: SessionStore
  let draft: ConversationDraft
  let composer: ConversationStore
  private(set) var initialized = false
  private(set) var worktrees: [WorktreeChoice] = []
  private(set) var rootBranch: String?
  private(set) var git = false
  private(set) var mcps: [MCPServer] = []
  private var mcpDefaults: [String: Bool] = [:]
  private var mcpOrder = MCPChipOrder()
  private(set) var mcpLoading = false
  private(set) var mcpError = false
  private(set) var loading = false
  private(set) var loadError: String?
  /// Listing failures keep root and Nova worktree available but must be visible, not an empty list.
  private(set) var worktreeError = false
  private(set) var toggling: Set<String> = []
  private var selectionRevision = 0
  @ObservationIgnored private var mutations: [UUID: Task<Bool, Never>] = [:]
  private let defaults: UserDefaults
  private let memoryKey: String
  private var categories: [String: String]
  private let origin: NewSessionOrigin?
  /// The originating conversation's model, applied to the draft; sending it unchanged is not a choice.
  private var inheritedModel: ModelReference?
  private let startInChats: Bool

  init(
    sessions: SessionStore, origin: NewSessionOrigin? = nil, startInChats: Bool = false,
    defaults: UserDefaults = .standard
  ) {
    self.sessions = sessions
    self.origin = origin
    self.startInChats = startInChats
    self.defaults = defaults
    let server = sessions.client.configuration.url.absoluteString
    draft = sessions.drafts.draft("new-session")
    composer = ConversationStore(
      id: "new-session", client: sessions.client, hub: sessions.hub, catalog: sessions.catalog)
    memoryKey = "OpenCodeNewSession." + server
    categories = defaults.dictionary(forKey: memoryKey + ".categories") as? [String: String] ?? [:]
    composer.newSessionSubmit = { [weak self] draft in await self?.send(draft) }
    composer.newSessionApps = { [weak self] in
      guard let self, !mcpError, !mcpLoading || !mcps.isEmpty else { return nil }
      return (ComposerAppScope.enabled(previewChips), preview)
    }
  }
  var projects: [Project] {
    NewSessionProjection.projects(
      sessions.projects, preferences: sessions.preferences, chatRoot: sessions.chatRoot)
  }
  var project: Project? {
    chat ? nil : projects.first { $0.id == draft.newSession?.projectID }
  }
  /// Managed chats need the plugin's `custom.chats`; older servers never offer them.
  var chatsAvailable: Bool { sessions.chatRoot != nil }
  var chat: Bool { chatsAvailable && draft.newSession?.chat != nil }
  var destination: SessionDestination { draft.newSession?.destination ?? .root }
  var baseBranch: String? { draft.newSession?.baseBranch ?? rootBranch }
  /// Before allocation a chat reads catalogs and MCP defaults from the chats root, like the master.
  var directory: String? {
    chat ? sessions.chatRoot : project.map { destination.directory(root: $0.canonical) }
  }
  /// Chats and new worktrees do not exist yet: MCP taps only record intent for them.
  var preview: Bool { chat || destination == .create }
  var loadKey: String {
    guard initialized else { return "" }
    return chat
      ? "chats:\(selectionRevision)"
      : "\(project?.id ?? ""):\(destination.key):\(selectionRevision)"
  }
  var directoryLabel: String {
    switch destination {
    case .root: rootBranch ?? "Diretório principal"
    case .create: "Nova worktree"
    case .worktree(let directory):
      worktrees.first { $0.directory == directory }?.label
        ?? URL(fileURLWithPath: directory).lastPathComponent
    }
  }
  var chips: [MCPServer] {
    mcpOrder.arrange(previewChips)
  }
  private var previewChips: [MCPServer] {
    mcps.map { server in
      if toggling.contains(server.name) {
        var pending = server
        pending.status = .init(.pending)
        return pending
      }
      return preview
        ? server.preview(
          draft.newSession?.intents[server.name], defaultEnabled: mcpDefaults[server.name] ?? true)
        : server
    }
  }
  func showMCPs() { mcpOrder.open(previewChips) }
  func hideMCPs() { mcpOrder.close() }
  func open() async {
    guard !initialized else { return }
    await draft.load()
    if sessions.preferences == nil { await sessions.reload() }
    let inherited = origin.flatMap { origin in projects.first { $0.id == origin.projectID } }
    // A restored draft with text or attachments is work in progress, not a default to replace.
    let restoredWork =
      !chat && draft.newSession != nil && (!draft.isEmpty || !draft.attachments.isEmpty)
    // An originating session wins. The Sessões "+" defaults to Chats, even over a repository
    // filter, unless it restores work in progress. Otherwise, like a repository filter, the Chats
    // filter wins, and a restored chat draft stays a chat.
    if chatsAvailable
      && (origin?.chat == true
        || (inherited == nil
          && ((startInChats && !restoredWork) || sessions.chatsSelected
            || (chat && !projects.contains { $0.id == sessions.selectedProject }))))
    {
      if !chat { draft.newSession = .chat(mcp: draft.newSession?.mcp ?? [:]) }
      if let model = origin?.model {
        draft.model = model
        inheritedModel = model
      }
      initialized = true
      draft.focused = true
      return
    }
    let restored = chat ? nil : projects.first { $0.id == draft.newSession?.projectID }
    let initial =
      inherited ?? projects.first { $0.id == sessions.selectedProject } ?? restored
      ?? NewSessionProjection.initialProject(
        projects, filtered: nil, last: sessions.preferences?.data.projects["local"]?.lastProject)
    if let origin, let inherited {
      draft.newSession = NewSessionContext(
        projectID: inherited.id, destination: origin.destination, mcp: draft.newSession?.mcp ?? [:])
      if let model = origin.model {
        draft.model = model
        inheritedModel = model
      }
    } else if let initial, initial.id != restored?.id {
      draft.newSession = NewSessionContext(
        projectID: initial.id,
        destination: .implicit(lastUsed: categories[initial.id]))
    }
    initialized = true
    draft.focused = initial != nil
    if let initial {
      do { try await sessions.touchProject(initial.canonical) } catch {
        composer.toast.show("Não foi possível guardar o último projeto usado.", kind: .error)
      }
    }
  }
  func selectChat() {
    guard !draft.sending, chatsAvailable, !chat else { return }
    draft.newSession = .chat(mcp: draft.newSession?.mcp ?? [:])
  }
  func selectProject(_ project: Project) async {
    guard !draft.sending else { return }
    if self.project?.id != project.id {
      draft.newSession = NewSessionContext(
        projectID: project.id,
        destination: .implicit(lastUsed: categories[project.id]), mcp: draft.newSession?.mcp ?? [:])
    }
    do { try await sessions.touchProject(project.canonical) } catch {
      composer.toast.show("Não foi possível guardar o último projeto usado.", kind: .error)
    }
  }
  func selectDestination(_ destination: SessionDestination) {
    guard !draft.sending else { return }
    draft.newSession?.destination = destination
    draft.newSession?.baseBranch = nil
    remember()
  }
  func selectBase(_ branch: String) { draft.newSession?.baseBranch = branch }
  private func remember() {
    guard !chat, let project else { return }
    categories[project.id] = destination.category
    defaults.set(categories, forKey: memoryKey + ".categories")
  }
  func reloadSelection() async {
    guard initialized, let directory else { return }
    guard let project else {
      if chat { await reloadChat(directory) }
      return
    }
    loading = true
    loadError = nil
    worktreeError = false
    mcpLoading = true
    mcpError = false
    mcps = []
    mcpOrder = MCPChipOrder()
    defer {
      if !Task.isCancelled {
        loading = false
        mcpLoading = false
      }
    }
    do {
      let client = sessions.client
      async let inventory = Self.attempt { try await client.refreshedWorktrees(projectID: project.id) }
      async let branches = Self.attempt {
        try await client.worktreeBranches(directory: project.canonical)
      }
      async let vcs = client.vcs(directory: project.canonical)
      async let catalog: Void = composer.loadNewSession(
        directory: directory, projectID: project.id, recent: sessions.catalog.recent)
      let values = try await (inventory, branches, vcs, catalog)
      try Task.checkCancellation()
      let listed = try? values.0.get()
      let checkouts = try? values.1.get()
      worktreeError = listed == nil || checkouts == nil
      rootBranch =
        values.2.branch.current ?? checkouts?.first { $0.directory == project.canonical }?.branch
      git = project.vcs == "git" || values.2.supportsWorktrees || rootBranch != nil
      worktrees = NewSessionProjection.worktrees(
        root: project.canonical, inventory: listed ?? project.worktrees ?? [],
        known: project.worktrees ?? [], sandboxes: project.sandboxes, branches: checkouts ?? [])
      if !git && destination != .root {
        selectDestination(.root)
        return
      }
      if case .worktree(let path) = destination,
        !worktrees.contains(where: { $0.directory == path }) && listed != nil
      {
        selectDestination(.implicit(lastUsed: categories[project.id]))
        return
      }
      await loadMCPs()
    } catch {
      if !Task.isCancelled {
        loadError = "Não foi possível carregar o diretório. \(error.localizedDescription)"
        mcpError = true
      }
    }
  }
  private func reloadChat(_ directory: String) async {
    loading = true
    loadError = nil
    mcps = []
    mcpOrder = MCPChipOrder()
    defer { if !Task.isCancelled { loading = false } }
    do {
      try await composer.loadNewSession(
        directory: directory, projectID: "global", recent: sessions.catalog.recent)
      try Task.checkCancellation()
      await loadMCPs()
    } catch {
      if !Task.isCancelled {
        loadError = "Não foi possível preparar o chat. \(error.localizedDescription)"
        mcpError = true
      }
    }
  }
  func retry() { selectionRevision += 1 }
  private nonisolated static func attempt<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async -> Result<Value, any Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }
  func loadMCPs() async {
    guard let directory else { return }
    mcpLoading = true
    mcpError = false
    defer { if !Task.isCancelled && directory == self.directory { mcpLoading = false } }
    do {
      async let servers = sessions.client.mcpServers(directory: directory)
      async let configuration = sessions.client.newSessionConfiguration(directory: directory)
      let value = try await (servers, configuration)
      try Task.checkCancellation()
      guard directory == self.directory else { return }
      mcpDefaults = MCPServer.defaults(value.1)
      mcps = value.0
      showMCPs()
      composer.prepareApps()
    } catch { if !Task.isCancelled && directory == self.directory { mcpError = true } }
  }
  func toggle(_ server: MCPServer) {
    guard !draft.sending, let directory, let context = draft.newSession else { return }
    switch server.toggle(preview: preview) {
    case .unavailable: return
    case .login:
      composer.toast.show(
        "Faça o login de \(server.name) pelo app web para conectar este MCP.", kind: .error)
    case .intent:
      draft.newSession?.mcp[context.intentKey, default: [:]][server.name] = !server.enabled
      composer.prepareApps()
      Haptics.play(.selection)
    case .live:
      guard toggling.insert(server.name).inserted else { return }
      draft.newSession?.mcp[context.intentKey, default: [:]][server.name] = !server.enabled
      let id = UUID()
      mutations[id] = Task {
        defer {
          toggling.remove(server.name)
          mutations[id] = nil
        }
        do {
          try await sessions.client.toggleMCP(
            server.name, enabled: !server.enabled, directory: directory)
          let updated = try await sessions.client.mcpServers(directory: directory)
          guard let value = updated.first(where: { $0.name == server.name }),
            !server.enabled ? value.status.status == .connected : value.status.status == .disabled
          else { throw MCPUIError() }
          if self.directory == directory && !preview {
            // Replace values in place: a tap must never change chip order.
            mcps = mcps.map { old in updated.first { $0.name == old.name } ?? old }
            composer.prepareApps()
          }
          Haptics.play(.selection)
          return true
        } catch {
          composer.toast.show(
            "Não foi possível alterar \(server.name). \(error.localizedDescription)", kind: .error)
          if self.directory == directory { await loadMCPs() }
          return false
        }
      }
    }
  }
  private func send(_ draft: ConversationDraft) async {
    guard !draft.sending, !draft.importing, composer.ready, !loading,
      let context = draft.newSession, chat || project != nil,
      let model = composer.selectedModel(draft)
    else { return }
    draft.sending = true
    draft.error = nil
    defer { draft.sending = false }
    let document: ComposerDocument
    do { document = try await composer.newSessionDocument(draft.document) } catch {
      composer.toast.show(
        "Não foi possível verificar o comando. Seu rascunho foi mantido.", kind: .error)
      return
    }
    let dispatch = ComposerDispatch.resolve(document)
    if case .local = dispatch {
      composer.toast.show("Este comando precisa de uma sessão existente.", kind: .error)
      return
    }
    for mutation in Array(mutations.values) {
      guard await mutation.value else { return }
    }
    let agent = composer.selectedAgent(draft)
    let command: String? = if case .command(let name, _) = dispatch { name } else { nil }
    let submission =
      if let chat = context.chat, self.chat {
        NewSessionSubmission(
          chat: chat, intents: draft.newSession?.intents ?? [:], agent: agent, model: model,
          command: command)
      } else {
        NewSessionSubmission(
          projectID: project?.id ?? "", root: project?.canonical ?? "",
          destination: context.destination, branch: baseBranch,
          intents: draft.newSession?.intents ?? [:], agent: agent, model: model, command: command)
      }
    let remembered = NewSessionProjection.remembered(
      explicit: draft.model, inherited: inheritedModel, sent: model,
      saved: composer.preferences?.data.models?.default)
    var snapshot = draft.snapshot
    snapshot.document = document
    let persistence = draft.persistence
    let client = sessions.client
    let input =
      composer.models.first { $0.id == model.id && $0.providerID == model.providerID }?
      .capabilities?.input ?? []
    remember()
    do {
      _ = try await submission.send(using: client) { [snapshot] directory in
        var delivered: [DeliveredAttachment] = []
        for item in snapshot.attachments {
          if let path = item.remotePath {
            delivered.append(.init(attachment: item, path: path, inline: nil))
            continue
          }
          let bytes = try await persistence.bytes(item)
          delivered.append(
            try await client.deliver(item, bytes: bytes, directory: directory, input: input))
        }
        return PromptRequest(
          document: snapshot.document, delivery: .steer, agent: agent, model: model,
          attachments: delivered, quotes: snapshot.quotes)
      }
      sessions.catalog.committed(model)
      remember(remembered)
      draft.didSend()
      await finish(id: submission.id, restore: nil)
      Haptics.play(.light)
    } catch let failure as NewSessionFailure {
      if let allocation = failure.allocation {
        draft.newSession?.chat?.allocation = allocation
        await draft.persist()
      }
      if let directory = failure.createdDirectory {
        let intents = draft.newSession?.intents ?? [:]
        draft.newSession?.destination = .worktree(directory)
        if let key = draft.newSession?.intentKey { draft.newSession?.mcp[key] = intents }
        await draft.persist()
      }
      if let id = failure.sessionID {
        remember(remembered)
        await finish(id: id, restore: snapshot)
        sessions.toast.show(failure.localizedDescription, kind: .error)
      } else {
        composer.toast.show(failure.localizedDescription, kind: .error)
      }
    } catch { composer.toast.show(error.localizedDescription, kind: .error) }
  }
  /// Once a Session exists, the model and effort deliberately chosen here become the default for
  /// the next new sessions. It does not delay opening the conversation.
  private func remember(_ model: ModelReference?) {
    guard let model else { return }
    let sessions = sessions
    Task {
      do { try await sessions.rememberNewSessionModel(model) } catch {
        sessions.toast.show(
          "Não foi possível guardar o modelo como padrão para novas sessões.", kind: .error)
      }
    }
  }
  private func finish(id: String, restore: DraftSnapshot?) async {
    if let restore {
      let target = sessions.drafts.draft(id)
      await target.load()
      for item in restore.attachments where item.remotePath == nil {
        do {
          try await target.persistence.store(draft.persistence.bytes(item), attachment: item)
        } catch {
          sessions.toast.show("Não foi possível transferir um anexo para a conversa.", kind: .error)
        }
      }
      target.text = restore.document.attributed
      target.attachments = restore.attachments
      target.quotes = restore.quotes
      target.model = restore.model ?? composer.selectedModel(draft)
      target.agent = restore.agent ?? composer.selectedAgent(draft)
      target.selection = NSRange(location: target.editorText.length, length: 0)
      target.expanded = draft.expanded
      await target.persist()
    }
    draft.focused = false
    draft.newSession = nil
    draft.model = nil
    draft.agent = nil
    await draft.clear()
    if sessions.conversationPath.last?.newSession == true {
      sessions.conversationPath[sessions.conversationPath.count - 1] = .init(id: id)
    }
  }
}
struct MCPUIError: LocalizedError {
  var errorDescription: String? {
    "O MCP não confirmou a alteração. Se precisar de login, entre pelo app web."
  }
}
