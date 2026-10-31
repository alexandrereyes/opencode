import Observation
import OpenCodeKit
import SwiftUI

/// The live data of the Contexto column for one session, the root or a subagent open over it (its own family,
/// subagents, cost and context): the same reads the iPhone's conversation and "Agentes e tarefas" use, refreshed
/// by the shared event stream.
@MainActor @Observable final class ContextColumnStore {
  let id: String
  let sessions: SessionStore
  private(set) var session: Session?
  private(set) var family: FamilySnapshot?
  /// Every descendant of the session (`custom.session-family/page`), with their context, tokens and cost.
  private(set) var members: [Session] = [] { didSet { familyIDs = Set([id] + members.map(\.id)) } }
  /// The session and its descendants, for matching each streamed event without rebuilding the set.
  @ObservationIgnored private var familyIDs: Set<String>
  /// The root's latest transcript page, oldest first: it links `subagent` calls and background shells.
  private(set) var messages: [ConversationMessage] = []
  private(set) var shells: [ShellInfo] = []
  private(set) var models: [ModelInfo] = []
  private(set) var agents: [AgentInfo] = []
  private(set) var changes: [WorkingChange] = []
  private(set) var located: LocatedDirectory?
  /// The folder's VCS (`GET /api/vcs`): its current branch, read again when a checkout changes it.
  private(set) var vcs: VCSInfo?
  private(set) var resources: [SessionResource] = []
  /// The current tool of each live subagent ("rodando bun test"), from its transcript preview.
  private(set) var activities: [String: String] = [:]
  private(set) var loaded = false
  private(set) var error: String?
  private(set) var acting: Set<String> = []
  /// Recursos' stage (`ResourceStage`): "Seguir o agente" puts the resource an agent uses now on it; choosing one by
  /// hand turns following off until Alexandre turns it back on. `stageControlling` keeps the stage while he holds
  /// control from it.
  var stageFollowing = true
  var stageChosen: String?
  var stageCurrent: String?
  var stageControlling = false
  /// "Limpar parados" asks first.
  var clearingStopped = false
  /// `+N ›`: every stopped resource as a chip.
  var stoppedExpanded = false
  /// Detalhes da sessão, read when that part of the column opens: loaded skills, plugins and the MCP servers.
  private(set) var services: SessionServices?
  var detailsOpen = false {
    didSet { if detailsOpen && !oldValue { Task { await loadDetails() } } }
  }
  @ObservationIgnored private var scheduled: Task<Void, Never>?
  @ObservationIgnored private var resourcesTask: Task<Void, Never>?
  @ObservationIgnored private var branchTask: Task<Void, Never>?
  #if DEBUG
  /// The column listening to the events (the one on screen) and how many times it read the server, for
  /// `MacAjustesChecks`.
  @ObservationIgnored static weak var shown: ContextColumnStore?
  @ObservationIgnored private(set) var loads = 0
  #endif

  init(id: String, sessions: SessionStore) {
    self.id = id
    self.sessions = sessions
    familyIDs = [id]
  }

  var client: OpenCodeClient { sessions.client }
  var directory: String? { session?.location.directory }
  /// The checkout root: working-copy diff paths are relative to it.
  var root: String { located?.worktree ?? directory ?? "/" }
  /// The summary line's worktree and branch.
  var checkout: ContextColumn.Checkout { ContextColumn.checkout(directory: directory, located: located, vcs: vcs) }
  var active: Set<String> { sessions.active.union(family?.active.map(\.id) ?? []) }
  var work: [SessionWork] {
    ConversationProjection.work(
      ownerID: id, viewedID: id, messages: messages, children: members, active: active, shells: shells)
  }
  var subagents: ContextColumn.Subagents {
    ContextColumn.subagents(
      work: work, rootID: id, members: members, models: models, permissions: family?.permissions ?? [],
      forms: family?.forms ?? [], resources: resources, progress: progress)
  }
  /// Each subagent's open Progresso (`2/4`): the `todowrite` calls the shared event stream saw, else the family
  /// snapshot's (the server's hub saw those from before the app opened); `SessionStore.progress(_:family:)`.
  private var progress: [String: ContextColumn.Progress] {
    Dictionary(uniqueKeysWithValues: members.compactMap { member in
      sessions.progress(member.id, family: family).flatMap {
        $0.open ? (member.id, ContextColumn.Progress(done: $0.done, total: $0.total)) : nil
      }
    })
  }
  var tasks: [SessionWork] { work.filter { $0.kind == .script } }
  var costs: ContextColumn.Costs { ContextColumn.costs(session: session, family: family, members: members) }
  /// The latest measured step of the session itself, like the iPhone composer's usage line.
  /// `GET /api/session/:id` may omit `context`; the transcript's latest measured step is the same fact.
  var usage: ContextUsage? {
    if let context = session?.context {
      return ContextUsage(tokens: context.tokens, limit: ContextUsage.limit(context.model, models: models))
    }
    guard let step = ConversationProjection.latestMeasurement(messages) else { return nil }
    return ContextUsage(tokens: step.tokens, limit: ContextUsage.limit(step.model, models: models))
  }
  /// The whole session's cache hit, like "Uso da sessão".
  var cacheHit: Double? { ContextUsage.cacheHit(session?.tokens ?? session?.context?.tokens) }
  var summary: ContextColumn.ChangeSummary { ContextColumn.summary(changes) }
  var statuses: [String: ContextColumn.FileStatus] { ContextColumn.statuses(changes, root: root) }
  func agent(_ id: String?) -> AgentInfo? { agents.first { $0.id == id } }
  /// The question a subagent is waiting on, answered in its own conversation.
  func question(_ sessionID: String?) -> PendingForm? { family?.forms.first { $0.sessionID == sessionID } }
  func title(_ sessionID: String) -> String? {
    work.first { $0.sessionID == sessionID }?.title ?? members.first { $0.id == sessionID }?.displayTitle
  }

  func run() async {
    #if DEBUG
    Self.shown = self
    #endif
    await load()
    for await frame in sessions.hub.events() {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected: schedule()
      case .disconnected: break
      case .update(let event) where event.type == OpenCodeClient.resourcesChangedEvent: scheduleResources()
      case .update(let event) where event.type == OpenCodeClient.branchUpdatedEvent: scheduleBranch()
      case .update(let event):
        guard event.data.owner.map(familyIDs.contains) == true || event.type.hasPrefix("rpc.") else { continue }
        // Streaming deltas only move the subagents' "agora" line; structural events reload everything.
        schedule(delay: event.type.hasSuffix(".delta") || event.type.hasSuffix(".progress") ? 2_000 : 700)
      }
    }
    scheduled?.cancel()
    resourcesTask?.cancel()
    branchTask?.cancel()
  }

  func load() async {
    #if DEBUG
    loads += 1
    #endif
    do {
      let session = try await client.session(id)
      let directory = session.location.directory
      async let familyValue = client.family(id)
      async let membersValue = familyMembers()
      async let messagesValue = try? Array(client.conversation(id).data.reversed())
      async let shellsValue = try? client.shells(directory: directory)
      async let modelsValue = models.isEmpty ? try? client.models(directory: directory) : models
      async let agentsValue = agents.isEmpty ? try? client.agents(directory: directory) : agents
      async let changesValue = try? client.workingChanges(directory: directory)
      async let locatedValue = try? client.locate([directory]).first
      async let vcsValue = try? client.vcs(directory: directory)
      async let resourcesValue = try? client.resources()
      let family = try await familyValue
      let members = try await membersValue
      self.session = session
      self.family = family
      self.members = members
      messages = await messagesValue ?? []
      shells = await shellsValue ?? []
      models = await modelsValue ?? []
      agents = await agentsValue ?? []
      changes = await changesValue ?? []
      located = await locatedValue
      vcs = await vcsValue ?? vcs
      resources = owned(await resourcesValue ?? [])
      loaded = true
      error = nil
      await loadActivities()
    } catch {
      guard !Task.isCancelled else { return }
      self.error = "Não foi possível carregar o contexto. \(error.localizedDescription)"
      loaded = true
    }
  }

  /// Only the live subagents read a preview, at most a few at a time like the Sessões rows.
  private func loadActivities() async {
    let live = subagents.shown.filter(\.status.live).compactMap(\.work.sessionID).prefix(8)
    var next: [String: String] = [:]
    await withTaskGroup(of: (String, String?).self) { group in
      for child in live {
        group.addTask { [client] in (child, try? await client.preview(child).activity) }
      }
      for await (child, activity) in group { next[child] = activity }
    }
    activities = next.compactMapValues { $0 }
  }

  private func familyMembers() async throws -> [Session] {
    var members: [Session] = []
    var after: String?
    repeat {
      let page = try await client.familyPage(id, after: after)
      members.append(contentsOf: page.data)
      if page.next == after { break }
      after = page.next
    } while after != nil
    return members
  }

  private func owned(_ all: [SessionResource]) -> [SessionResource] {
    let family = Set([id] + members.map(\.id))
    return all.filter { resource in
      guard let owner = resource.owner else { return false }
      return owner.rootSessionID == id || family.contains(owner.sessionID)
    }
  }

  private func schedule(delay: Int = 700) {
    guard scheduled == nil else { return }
    scheduled = Task {
      try? await Task.sleep(for: .milliseconds(delay))
      scheduled = nil
      guard !Task.isCancelled else { return }
      await load()
    }
  }

  private func scheduleResources() {
    guard resourcesTask == nil else { return }
    resourcesTask = Task {
      try? await Task.sleep(for: .milliseconds(300))
      resourcesTask = nil
      guard !Task.isCancelled, let all = try? await client.resources() else { return }
      let next = owned(all)
      if next != resources { resources = next }
    }
  }

  /// A checkout in any folder (the app does not decode the event's location): the shown folder's VCS is read again,
  /// one cached read on the server, like the web app does on the same event.
  private func scheduleBranch() {
    guard branchTask == nil else { return }
    branchTask = Task {
      try? await Task.sleep(for: .milliseconds(300))
      branchTask = nil
      guard !Task.isCancelled, let directory, let next = try? await client.vcs(directory: directory) else { return }
      vcs = next
    }
  }

  func reply(_ permission: PermissionRequest, allow: Bool) async {
    await act(permission.id) { try await self.client.reply(permission, allow: allow) }
  }

  func stop(_ work: SessionWork) async {
    await act(work.id) {
      if let child = work.sessionID { try await self.client.interrupt(child) }
      if let shell = work.shellID, let directory = self.directory {
        try await self.client.stopShell(shell, directory: directory)
      }
    }
  }

  /// Skills and plugins, like the iPhone's Detalhes da sessão; reread each time the part opens. MCPs live in their
  /// own section, on the conversation's `ConversationMCPStore`.
  func loadDetails() async {
    guard let directory else { return }
    services = await client.sessionServices(sessionID: id, directory: directory)
  }

  func dismiss(_ resource: SessionResource) async {
    await act(resource.id) { try await self.client.dismissResource(resource.id) }
  }

  /// The resource on the stage now: following, the agent's; by hand, the chosen one; else the current or the first.
  var stageID: String? {
    ResourceStage.pick(ResourceStage.on(resources), following: stageFollowing, chosen: stageChosen,
      current: stageCurrent, controlling: stageControlling)
  }

  /// A thumbnail clicked: it takes the stage and following stops.
  func choose(_ resource: SessionResource) {
    stageChosen = resource.id
    stageFollowing = false
  }

  /// "Seguir o agente" back on: the agent's resource takes the stage again.
  func follow(_ on: Bool) {
    stageFollowing = on
    if on { stageChosen = nil }
  }

  /// "Limpar parados": Encerrar on each stopped resource, then one reload.
  func dismissStopped() async {
    let stopped = ResourceStage.off(resources)
    guard !stopped.isEmpty, acting.insert("stopped").inserted else { return }
    defer { acting.remove("stopped") }
    var failed = 0
    for resource in stopped {
      do { try await client.dismissResource(resource.id) } catch { failed += 1 }
    }
    await load()
    if failed > 0 {
      sessions.toast.show("Não foi possível limpar \(failed) de \(stopped.count) recursos parados.", kind: .error)
    }
  }

  private func act(_ key: String, _ action: @escaping () async throws -> Void) async {
    guard acting.insert(key).inserted else { return }
    defer { acting.remove(key) }
    do {
      try await action()
      await load()
    } catch {
      sessions.toast.show("Não foi possível concluir a ação. \(error.localizedDescription)", kind: .error)
    }
  }
}
