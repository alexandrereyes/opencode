import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// Nova sessão on the Mac, as a sheet: the iPhone's choices (Chats or a project, its main checkout, an existing
/// worktree or a new one from a base branch, the MCPs, the model, effort and agent) with Mac controls: pop-up menus
/// instead of selector sheets, ⌘Return to send. The decisions are OpenCodeKit's (`NewSessionProjection`,
/// `NewSessionSubmission`), like the iPhone's `NewSessionStore`. The prompt is the chat's composer (`MacComposer`
/// embedded: tokens, suggestions, attachments and the persistent `new-session` draft), over a composer
/// `ConversationStore` in its new-session mode, as on the iPhone.
struct MacNewSession: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var store: MacNewSessionStore
  @State private var addingProject = false
  @State private var choosingBase = false
  let runtime: MacWindowRuntime

  init(store sessions: SessionStore, runtime: MacWindowRuntime, request: MacNewSessionRequest) {
    _store = State(initialValue: MacNewSessionStore(sessions: sessions, request: request, drafts: runtime.drafts))
    self.runtime = runtime
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      FloatingVoiceHost()
      if store.master || store.chat || store.project != nil {
        if !store.master { selectors }
        mcps
        editor
        footer
      } else if !store.initialized {
        ProgressView("Carregando projetos…").frame(maxWidth: .infinity, minHeight: 200)
      } else {
        ContentUnavailableView {
          Label("Nenhum projeto selecionado", systemImage: "folder")
        } description: {
          Text("Adicione um projeto para começar uma sessão.")
        } actions: {
          Button("Adicionar projeto…") { addingProject = true }
          if store.chatsAvailable { Button("Conversar em Chats") { store.selectChat() } }
        }
        .frame(minHeight: 220)
        HStack { Spacer(); Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
      }
    }
    .padding(22)
    .frame(width: 620)
    .background(theme.color(.background))
    .modifier(FloatingVoiceScope())
    .toastOverlay(store.toast)
    .task { await store.open() }
    .onAppear { runtime.newSessionPalette = openModelPalette }
    .onDisappear { runtime.newSessionPalette = nil; runtime.modelPalette.close() }
    .task {
      await store.draft.load()
      store.draft.focused = true
    }
    .task(id: store.loadKey) { await store.reload() }
    .onChange(of: store.created) { _, id in
      guard let id else { return }
      runtime.selection = MacSelection(sessionID: id, master: store.master)
      dismiss()
    }
    .sheet(isPresented: $addingProject) {
      AddProjectPicker(store: store.sessions) { project in await store.selectProject(project) }.macCancelable()
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      if store.master {
        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 18, weight: .medium))
          .foregroundStyle(theme.color(.accent)).frame(width: 40, height: 40)
          .background(theme.color(.highlight), in: Circle())
      } else if let project = store.project {
        ProjectAvatar(project: project, size: 40, style: .message)
      } else {
        ChatsAvatar(size: 40, symbol: .action)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(store.master ? "Sessão mestra" : "Nova sessão").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        Text(store.question).appFont(.title, weight: .semibold).foregroundStyle(theme.color(.textStrong))
      }
      Spacer()
    }
  }

  /// Projeto, then Diretório (or `+ Nova worktree` and `a partir de …`), as pop-up menus.
  private var selectors: some View {
    HStack(spacing: 18) {
      Menu {
        if store.chatsAvailable {
          Button { store.selectChat() } label: { Label("Chats", systemImage: store.chat ? "checkmark" : "bubble.left") }
          Divider()
        }
        ForEach(store.projects) { project in
          Button {
            Task { await store.selectProject(project) }
          } label: {
            if store.project?.id == project.id { Label(project.displayName, systemImage: "checkmark") }
            else { Text(project.displayName) }
          }
        }
        Divider()
        Button("Adicionar projeto…", systemImage: "plus") { addingProject = true }
      } label: {
        HStack(spacing: 7) {
          if let project = store.project { ProjectAvatar(project: project, size: 20, style: .micro) }
          else { ChatsAvatar(size: 20, symbol: .inline) }
          Text(store.project?.displayName ?? "Chats")
          chevron
        }
      }
      .accessibilityLabel("Projeto: \(store.project?.displayName ?? "Chats")")
      if !store.chat {
        Menu {
          Section("Diretório principal") { choice(store.rootBranch ?? "Diretório principal", .root) }
          if store.git {
            Section("Worktrees") {
              ForEach(store.worktrees) { worktree in choice(worktree.label, .worktree(worktree.directory)) }
              if store.worktreeError {
                Button("Não foi possível listar as worktrees · Tentar novamente") { store.retry() }
              } else if store.worktrees.isEmpty {
                Text("Nenhuma worktree existente")
              }
            }
            Divider()
            Button { store.selectDestination(.create) } label: {
              Label("Nova worktree", systemImage: store.destination == .create ? "checkmark" : "plus")
            }
          }
        } label: {
          HStack(spacing: 7) {
            Group {
              if store.destination == .create { Image(systemName: "plus") } else { GitBranchIcon() }
            }.foregroundStyle(theme.color(.icon))
            Text(store.git || store.loading ? store.directoryLabel : "Sem Git")
            chevron
          }
        }
        .accessibilityLabel("Diretório: \(store.directoryLabel)")
        if store.destination == .create {
          Button { choosingBase = true } label: {
            HStack(spacing: 7) {
              GitBranchIcon().foregroundStyle(theme.color(.icon))
              Text("a partir de \(store.baseBranch ?? "HEAD")")
              chevron
            }
          }
          .popover(isPresented: $choosingBase, arrowEdge: .bottom) { MacBaseBranchPicker(store: store) }
        }
      }
      Spacer(minLength: 0)
      if store.loading { ProgressView().controlSize(.small) }
    }
    .appFont(.secondary).foregroundStyle(theme.color(.text))
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
    .disabled(store.sending)
  }

  private func choice(_ title: String, _ destination: SessionDestination) -> some View {
    Button { store.selectDestination(destination) } label: {
      if store.destination == destination { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.color(.textSecondary))
  }

  /// The iPhone's MCP chips: live switches on an existing checkout, intents for Chats and a new worktree.
  @ViewBuilder private var mcps: some View {
    if !store.master {
      VStack(alignment: .leading, spacing: 7) {
        if store.mcpLoading {
          ProgressView("Carregando MCPs…").controlSize(.small).appFont(.caption)
        } else if store.mcpError {
          Button("Não foi possível carregar MCPs · Tentar novamente") { store.retry() }
            .buttonStyle(.plain).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        } else if store.chips.isEmpty {
          Text("Nenhum MCP configurado").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        } else {
          MCPFlowLayout(spacing: 7, centered: false) {
            ForEach(store.chips) { server in
              MCPChip(server: server, preview: store.preview, chat: store.chat) { store.toggle(server) }
            }
          }
          .disabled(store.sending)
        }
        if store.preview {
          Text(store.chat ? "Vale quando o chat for criado" : "Vale quando a worktree for criada")
            .appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
        }
      }
    }
  }

  /// The chat's composer without its model, MCP and agent controls, which this sheet shows itself; Return sends,
  /// like the chat (⌘Return too, from the footer's Enviar).
  private var editor: some View {
    MacComposer(store: store.composer, draft: store.draft,
      embedded: MacComposerEmbedding(canSubmit: store.canSend, submit: { Task { await store.send() } }),
      features: .newSession)
      .disabled(store.sending)
      .accessibilityLabel("Mensagem")
  }

  /// The model with its effort and the agent, then Cancelar and Enviar (⌘Return).
  private var footer: some View {
    HStack(spacing: 10) {
      Button(action: openModelPalette) {
        Text(store.modelLabel).appFont(.chrome).lineLimit(1).foregroundStyle(theme.color(.text))
          .composerCapsule(horizontal: 9)
      }
      .help("Modelo e esforço (⌥⌘M)")
      if !store.master {
        Menu {
          ForEach(store.primaryAgents, id: \.id) { agent in
            Button(agent.name) { store.agent = agent.id }
          }
        } label: {
          HStack(spacing: 4) {
            Circle().fill(theme.agentColor(store.agents.first { $0.id == store.selectedAgent }, id: store.selectedAgent))
              .frame(width: 6, height: 6)
            Text(store.primaryAgents.first { $0.id == store.selectedAgent }?.name ?? store.selectedAgent)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
          }
          .appFont(.footnote).foregroundStyle(theme.color(.text))
        }
        .help("Agente")
      }
      Spacer()
      if let error = store.loadError {
        Button(error) { store.retry() }.buttonStyle(.plain).appFont(.caption).foregroundStyle(theme.color(.error))
          .lineLimit(1).help(error)
      }
      Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
      Button(store.sending ? "Enviando…" : "Enviar") { Task { await store.send() } }
        .shortcut(.createSession)
        .buttonStyle(.borderedProminent)
        .disabled(!store.canSend)
        .help("Enviar (⌘Return)")
    }
    .menuStyle(.button).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
    .buttonStyle(.plain)
  }

  private func openModelPalette() {
    store.draft.focused = false
    store.draft.focusSuppressed = true
    runtime.modelPalette.open(window: runtime.window, sessions: store.sessions, models: store.models,
      providers: store.composer.providers, current: store.selectedModel, theme: theme,
      restore: { store.draft.focusSuppressed = false; store.draft.focused = true }) { store.choosePaletteModel($0) }
  }
}

private struct MacMCPError: LocalizedError {
  var errorDescription: String? { "O MCP não confirmou a alteração. Se precisar de login, entre pelo app web." }
}

/// `a partir de …`: the root's branches (`/api/vcs/branch`), searched as you type, the current one first.
private struct MacBaseBranchPicker: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: MacNewSessionStore
  @State private var search = ""
  @State private var branches: [String] = []
  @State private var loading = true
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Buscar branches", text: $search).textFieldStyle(.roundedBorder)
        .onSubmit { if let first = branches.first { choose(first) } }
      List {
        if loading { ProgressView().controlSize(.small) }
        if failed { Text("Não foi possível carregar as branches.").foregroundStyle(theme.color(.error)) }
        ForEach(branches, id: \.self) { branch in
          Button { choose(branch) } label: {
            HStack {
              GitBranchIcon().foregroundStyle(theme.color(.icon))
              Text(branch).foregroundStyle(theme.color(.text))
              Spacer()
              if branch == store.baseBranch { Image(systemName: "checkmark").foregroundStyle(theme.color(.primary)) }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if !loading && !failed && branches.isEmpty { Text("Nenhuma branch encontrada") }
      }
      .listStyle(.plain)
      .frame(height: 260)
    }
    .padding(12).frame(width: 320)
    .task(id: search) {
      loading = true
      failed = false
      do {
        try await Task.sleep(for: .milliseconds(100))
        guard let root = store.project?.canonical else { return }
        let values = try await store.sessions.client.baseBranches(
          directory: root, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
        branches = NewSessionProjection.branches(values, current: store.rootBranch, search: search)
        loading = false
      } catch {
        guard !Task.isCancelled else { return }
        failed = true
        loading = false
      }
    }
  }

  private func choose(_ branch: String) {
    store.selectBase(branch)
    dismiss()
  }
}

/// The state and decisions of the Mac's Nova sessão, mirroring the iPhone's `NewSessionStore` over the same
/// OpenCodeKit projections, with a plain text prompt in place of the iPhone composer's draft.
@MainActor @Observable final class MacNewSessionStore {
  let sessions: SessionStore
  let master: Bool
  let toast = ToastCenter()
  /// The prompt: the persistent Nova sessão draft (tokens, attachments) and the composer store whose
  /// `loadNewSession` feeds its suggestions, like the iPhone's `NewSessionStore`.
  let draft: ConversationDraft
  let composer: ConversationStore
  /// An explicit model or agent chosen here; nil follows the projection (saved default, agent, configuration…).
  var model: ModelReference?
  var agent: String?
  private(set) var context: NewSessionContext?
  private(set) var initialized = false
  private(set) var worktrees: [WorktreeChoice] = []
  private(set) var rootBranch: String?
  private(set) var git = false
  private(set) var models: [ModelInfo] = []
  private(set) var agents: [AgentInfo] = []
  private(set) var configuration: [NewSessionConfiguration] = []
  private(set) var mcps: [MCPServer] = []
  private(set) var mcpLoading = false
  private(set) var mcpError = false
  private(set) var loading = false
  private(set) var loadError: String?
  private(set) var worktreeError = false
  private(set) var toggling: Set<String> = []
  private(set) var sending = false
  /// The session created by Enviar; the sheet selects it and closes.
  private(set) var created: String?
  private var masterModel: ModelReference?
  private var mcpDefaults: [String: Bool] = [:]
  private var mcpOrder = MCPChipOrder()
  private var revision = 0
  private var categories: [String: String]
  private let memoryKey: String
  private let origin: NewSessionOrigin?
  private let startInChats: Bool
  private var inheritedModel: ModelReference?

  /// Return is a choice for this session; only the palette's explicit ⌘Return writes the shared default.
  func choosePaletteModel(_ value: ModelReference) {
    model = value
    inheritedModel = value
  }
  @ObservationIgnored private var pendingTouch: String?
  @ObservationIgnored private var mutations: [UUID: Task<Bool, Never>] = [:]

  init(sessions: SessionStore, request: MacNewSessionRequest, drafts: ConversationDrafts? = nil) {
    self.sessions = sessions
    master = request.master
    origin = request.origin
    startInChats = request.startInChats
    memoryKey = "OpenCodeNewSession." + sessions.client.configuration.url.absoluteString
    draft = (drafts ?? sessions.drafts).draft(request.master ? "new-session-master" : "new-session")
    #if DEBUG
    MacSyntheticKey.fakeDictation(draft)
    #endif
    composer = ConversationStore(id: "new-session", client: sessions.client, hub: sessions.hub,
      catalog: sessions.catalog)
    categories = UserDefaults.standard.dictionary(forKey: memoryKey + ".categories") as? [String: String] ?? [:]
    composer.newSessionSubmit = { [weak self] _ in await self?.send() }
    composer.newSessionApps = { [weak self] in
      guard let self, !mcpError, !mcpLoading || !mcps.isEmpty else { return nil }
      return (ComposerAppScope.enabled(previewChips), preview)
    }
  }

  var projects: [Project] {
    NewSessionProjection.projects(sessions.projects, preferences: sessions.preferences, chatRoot: sessions.chatRoot)
  }
  var project: Project? { chat || master ? nil : projects.first { $0.id == context?.projectID } }
  var chatsAvailable: Bool { sessions.chatRoot != nil }
  var chat: Bool { chatsAvailable && context?.chat != nil }
  var destination: SessionDestination { context?.destination ?? .root }
  var baseBranch: String? { context?.baseBranch ?? rootBranch }
  var directory: String? {
    if master || chat { return sessions.chatRoot }
    return project.map { destination.directory(root: $0.canonical) }
  }
  /// Chats and new worktrees do not exist yet: MCP taps only record intent for them.
  var preview: Bool { chat || destination == .create }
  var loadKey: String {
    guard initialized else { return "" }
    return master ? "master:\(revision)" : chat ? "chats:\(revision)" : "\(project?.id ?? ""):\(destination.key):\(revision)"
  }
  var question: String {
    if master { return "Como posso ajudar com suas sessões?" }
    return project.map { "No que vamos trabalhar em \($0.displayName)?" } ?? "Sobre o que vamos conversar?"
  }
  var directoryLabel: String {
    switch destination {
    case .root: rootBranch ?? "Diretório principal"
    case .create: "Nova worktree"
    case .worktree(let directory):
      worktrees.first { $0.directory == directory }?.label ?? URL(fileURLWithPath: directory).lastPathComponent
    }
  }
  var chips: [MCPServer] { mcpOrder.arrange(previewChips) }
  private var previewChips: [MCPServer] {
    mcps.map { server in
      if toggling.contains(server.name) {
        var pending = server
        pending.status = .init(.pending)
        return pending
      }
      return preview ? server.preview(context?.intents[server.name], defaultEnabled: mcpDefaults[server.name] ?? true) : server
    }
  }
  var visibleModels: [ModelInfo] {
    ConversationProjection.visibleModels(models, preferences: sessions.preferences?.data.models)
  }
  var primaryAgents: [AgentInfo] { agents.filter { $0.mode != "subagent" && $0.hidden != true } }
  var selectedAgent: String {
    if master { return "mestra" }
    return NewSessionProjection.agent(
      explicit: agent, configured: configuration.compactMap(\.info.default_agent).last, agents: agents)
  }
  var selectedModel: ModelReference? {
    if master { return model ?? masterModel }
    let configured = agents.first { $0.id == selectedAgent }
    var agentModel = configured?.model
    if let variant = configured?.variant { agentModel?.variant = variant }
    return NewSessionProjection.model(
      explicit: model, preferences: sessions.preferences?.data.models, agent: agentModel,
      configured: configuration.compactMap(\.info.model).last, recent: sessions.catalog.recent, models: models)
  }
  var modelLabel: String {
    guard let selected = selectedModel else { return models.isEmpty ? "Carregando modelos…" : "Escolher modelo" }
    return [
      models.first { $0.id == selected.id && $0.providerID == selected.providerID }?.name ?? selected.id,
      selected.variant,
    ].compactMap { $0 }.joined(separator: " · ")
  }
  var canSend: Bool {
    !sending && !loading && selectedModel != nil && (master || chat || project != nil)
      && !draft.importing && (draft.hasText || draft.attachments.contains { $0.quoteID == nil })
  }

  func open() async {
    guard !initialized else { return }
    if sessions.preferences == nil { await sessions.reload() }
    defer { initialized = true }
    if master { return }
    let start = NewSessionProjection.start(
      projects: projects, origin: origin, chatsAvailable: chatsAvailable, chatsFilter: sessions.chatsSelected,
      filterProjectID: sessions.selectedProject, startInChats: startInChats, restoredChat: false,
      restoredProjectID: nil, restoredWork: false,
      lastProject: sessions.preferences?.data.projects["local"]?.lastProject, categories: categories)
    switch start {
    case .chats:
      context = .chat()
      if origin?.chat == true { inherit() }
    case .none: context = nil
    case .project(let id, let destination, let remember):
      context = NewSessionContext(projectID: id, destination: destination ?? .implicit(lastUsed: categories[id]))
      if origin?.projectID == id { inherit() }
      guard let project = projects.first(where: { $0.id == id }) else { return }
      if remember { try? await sessions.touchProject(project.canonical) } else { pendingTouch = project.canonical }
    }
  }

  /// Nova sessão from a session starts with that session's model and effort; sending it unchanged is no choice.
  private func inherit() {
    guard let inherited = origin?.model else { return }
    model = inherited
    inheritedModel = inherited
  }

  func selectChat() {
    guard !sending, chatsAvailable, !chat else { return }
    context = .chat(mcp: context?.mcp ?? [:])
  }

  func selectProject(_ project: Project) async {
    guard !sending else { return }
    pendingTouch = nil
    if self.project?.id != project.id {
      context = NewSessionContext(
        projectID: project.id, destination: .implicit(lastUsed: categories[project.id]), mcp: context?.mcp ?? [:])
    }
    try? await sessions.touchProject(project.canonical)
  }

  func selectDestination(_ destination: SessionDestination) {
    guard !sending else { return }
    context?.destination = destination
    context?.baseBranch = nil
    remember()
  }

  func selectBase(_ branch: String) { context?.baseBranch = branch }
  func retry() { revision += 1 }

  /// The destination category per project, like the iPhone and the web's "last used" rule.
  private func remember() {
    guard !chat, let project else { return }
    categories[project.id] = destination.category
    UserDefaults.standard.set(categories, forKey: memoryKey + ".categories")
  }

  func reload() async {
    guard initialized, let directory else { return }
    loading = true
    loadError = nil
    worktreeError = false
    mcps = []
    mcpOrder = MCPChipOrder()
    defer { if !Task.isCancelled { loading = false } }
    do {
      if master {
        let info = try await sessions.client.masterInfo()
        let fallback = info.model == nil ? try await sessions.client.defaultModel(directory: directory) : nil
        masterModel = info.model ?? fallback.map { ModelReference(id: $0.id, providerID: $0.providerID) }
        try await loadCatalog(directory)
        return
      }
      guard let project else {
        try await loadCatalog(directory)
        await loadMCPs()
        return
      }
      let client = sessions.client
      async let inventory = Self.attempt { try await client.refreshedWorktrees(projectID: project.id) }
      async let branches = Self.attempt { try await client.worktreeBranches(directory: project.canonical) }
      async let vcs = client.vcs(directory: project.canonical)
      async let catalog: Void = loadCatalog(directory)
      let values = try await (inventory, branches, vcs, catalog)
      try Task.checkCancellation()
      let listed = try? values.0.get()
      let checkouts = try? values.1.get()
      worktreeError = listed == nil || checkouts == nil
      rootBranch = values.2.branch.current ?? checkouts?.first { $0.directory == project.canonical }?.branch
      git = project.vcs == "git" || values.2.supportsWorktrees || rootBranch != nil
      worktrees = NewSessionProjection.worktrees(
        root: project.canonical, inventory: listed ?? project.worktrees ?? [], known: project.worktrees ?? [],
        sandboxes: project.sandboxes, branches: checkouts ?? [])
      if !git && destination != .root { return selectDestination(.root) }
      if case .worktree(let path) = destination, !worktrees.contains(where: { $0.directory == path }), listed != nil {
        return selectDestination(.implicit(lastUsed: categories[project.id]))
      }
      await loadMCPs()
    } catch {
      guard !Task.isCancelled else { return }
      loadError = "Não foi possível carregar o diretório."
      mcpError = true
    }
  }

  private func loadCatalog(_ directory: String) async throws {
    async let models = sessions.client.models(directory: directory)
    async let agents = sessions.client.agents(directory: directory)
    async let configuration = sessions.client.newSessionConfiguration(directory: directory)
    // The composer's own catalog: suggestions (`@` agents, `/` commands, `$` skills…) for this directory.
    async let composer: Void = self.composer.loadNewSession(
      directory: directory, projectID: project?.id ?? "global", recent: sessions.catalog.recent)
    let values = try await (models, agents, configuration, composer)
    try Task.checkCancellation()
    self.models = values.0
    self.agents = values.1
    self.configuration = values.2
    sessions.catalog.remember(values.0)
  }

  private nonisolated static func attempt<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async -> Result<Value, any Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
  }

  private func loadMCPs() async {
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
      mcpOrder.open(previewChips)
    } catch { if !Task.isCancelled && directory == self.directory { mcpError = true } }
  }

  func toggle(_ server: MCPServer) {
    guard !sending, let directory, let current = context else { return }
    switch server.toggle(preview: preview) {
    case .unavailable: return
    case .login: toast.show("Faça o login de \(server.name) pelo app web para conectar este MCP.", kind: .error)
    case .intent: context?.mcp[current.intentKey, default: [:]][server.name] = !server.enabled
    case .live:
      guard toggling.insert(server.name).inserted else { return }
      context?.mcp[current.intentKey, default: [:]][server.name] = !server.enabled
      let id = UUID()
      mutations[id] = Task {
        defer {
          toggling.remove(server.name)
          mutations[id] = nil
        }
        do {
          try await sessions.client.toggleMCP(server.name, enabled: !server.enabled, directory: directory)
          let updated = try await sessions.client.mcpServers(directory: directory)
          guard let value = updated.first(where: { $0.name == server.name }),
            !server.enabled ? value.status.status == .connected : value.status.status == .disabled
          else { throw MacMCPError() }
          if self.directory == directory && !preview { mcps = mcps.map { old in updated.first { $0.name == old.name } ?? old } }
          return true
        } catch {
          toast.show("Não foi possível alterar \(server.name). \(error.localizedDescription)", kind: .error)
          if self.directory == directory { await loadMCPs() }
          return false
        }
      }
    }
  }

  func send() async {
    guard canSend, let model = selectedModel else { return }
    sending = true
    draft.sending = true
    defer {
      sending = false
      draft.sending = false
    }
    for mutation in Array(mutations.values) {
      guard await mutation.value else { return }
    }
    // A leading `/command` token runs the command on the new session, like the iPhone.
    let document: ComposerDocument
    do { document = try await composer.newSessionDocument(draft.document) } catch {
      toast.show("Não foi possível verificar o comando. Seu rascunho foi mantido.", kind: .error)
      return
    }
    let dispatch = ComposerDispatch.resolve(document)
    if case .local = dispatch {
      toast.show("Este comando precisa de uma sessão existente.", kind: .error)
      return
    }
    let command: String? = if case .command(let name, _) = dispatch { name } else { nil }
    let agent = selectedAgent
    let request = prompt(document, agent: master ? "mestra" : agent, model: model)
    if master { return await sendMaster(request, model: model) }
    guard let context else { return }
    let submission =
      if let chat = context.chat, self.chat {
        NewSessionSubmission(chat: chat, intents: context.intents, agent: agent, model: model, command: command)
      } else {
        NewSessionSubmission(
          projectID: project?.id ?? "", root: project?.canonical ?? "", destination: context.destination,
          branch: baseBranch, intents: context.intents, agent: agent, model: model, command: command)
      }
    let remembered = NewSessionProjection.remembered(
      explicit: self.model, inherited: inheritedModel, sent: model, saved: sessions.preferences?.data.models?.default)
    remember()
    do {
      _ = try await submission.send(using: sessions.client) { directory in try await request(directory) }
      sessions.catalog.committed(model)
      keep(remembered)
      if let touch = pendingTouch, touch == project?.canonical { try? await sessions.touchProject(touch) }
      await finishDraft()
      await sessions.reload()
      created = submission.id
    } catch let failure as NewSessionFailure {
      if let allocation = failure.allocation { self.context?.chat?.allocation = allocation }
      if let directory = failure.createdDirectory {
        let intents = context.intents
        self.context?.destination = .worktree(directory)
        if let key = self.context?.intentKey { self.context?.mcp[key] = intents }
      }
      if let id = failure.sessionID {
        keep(remembered)
        await sessions.reload()
        sessions.toast.show(failure.localizedDescription, kind: .error)
        created = id
      } else {
        toast.show(failure.localizedDescription, kind: .error)
      }
    } catch {
      toast.show(error.localizedDescription, kind: .error)
    }
  }

  /// The prompt for a directory: the draft's document, its attachments delivered there, and its quotes.
  private func prompt(_ document: ComposerDocument, agent: String, model: ModelReference)
    -> @Sendable (String) async throws -> PromptRequest
  {
    let snapshot = draft.snapshot
    let persistence = draft.persistence
    let client = sessions.client
    let input = models.first { $0.id == model.id && $0.providerID == model.providerID }?.capabilities?.input ?? []
    return { directory in
      var delivered: [DeliveredAttachment] = []
      for item in snapshot.attachments {
        if let path = item.remotePath {
          delivered.append(.init(attachment: item, path: path, inline: nil))
          continue
        }
        let bytes = try await persistence.bytes(item)
        delivered.append(try await client.deliver(item, bytes: bytes, directory: directory, input: input))
      }
      return PromptRequest(document: document, delivery: .steer, agent: agent, model: model, attachments: delivered,
        quotes: snapshot.quotes)
    }
  }

  private func finishDraft() async {
    draft.didSend()
    await draft.clear()
  }

  /// The first message creates the master (`custom.master/ensure`), like the iPhone's empty master screen.
  private func sendMaster(_ request: @Sendable (String) async throws -> PromptRequest, model: ModelReference) async {
    do {
      let ensured = try await sessions.client.ensureMaster(model: model)
      do {
        try await sessions.client.prompt(try await request(sessions.chatRoot ?? ""), sessionID: ensured.sessionID)
        await finishDraft()
      } catch {
        sessions.toast.show("A sessão foi criada, mas a mensagem não foi enviada.", kind: .error)
      }
      sessions.adoptMaster(ensured.preferences)
      created = ensured.sessionID
    } catch {
      toast.show("Não foi possível criar a Sessão mestra.", kind: .error)
    }
  }

  /// A model and effort deliberately chosen here becomes the default for new sessions, as on the iPhone.
  private func keep(_ model: ModelReference?) {
    guard let model else { return }
    let sessions = sessions
    Task {
      do { try await sessions.rememberNewSessionModel(model) } catch {
        sessions.toast.show("Não foi possível guardar o modelo como padrão para novas sessões.", kind: .error)
      }
    }
  }
}
