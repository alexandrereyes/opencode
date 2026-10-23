import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable
final class SessionStore {
  let acceptsLaunchSession: Bool
  private(set) var entries: [NavigationEntry] = []
  private(set) var projects: [Project] = []
  private(set) var preferences: Preferences?
  let quota: SubscriptionStore
  private(set) var previews: [String: SessionPreview] = [:]
  private(set) var permissions: [PermissionRequest] = []
  private(set) var forms: [PendingForm] = []
  private(set) var archived: [Session] = []
  private(set) var directoryMetadata = SessionDirectoryCache()
  private(set) var active: Set<String> = []
  private(set) var loading = false
  private(set) var connected = false
  private(set) var serverVersion: String?
  private(set) var masterAvailability = MasterAvailability.loading
  var masterID: String? {
    guard let id = preferences?.data.masterSessions?["local"],
      !archived.contains(where: { $0.id == id }) else { return nil }
    return id
  }
  func loadMaster() async {
    do {
      let info = try await client.masterInfo()
      try Task.checkCancellation()
      masterAvailability = info.version == 1 ? .available : .unsupported
    } catch { if !Task.isCancelled { masterAvailability = .classify(error) } }
  }
  func adoptMaster(_ preferences: Preferences) { self.preferences = preferences }
  func resetMaster() async {
    guard let id = masterID, busy.insert("master-reset").inserted else { return }
    defer { busy.remove("master-reset") }
    do {
      try await client.archive(id)
      preferences = try await client.mutate(.masterClear)
      toast.show("Sessão mestra arquivada")
      Haptics.play(.light)
    } catch { toast.show("Não foi possível reiniciar a Sessão mestra.", kind: .error) }
    await reload()
  }
  private(set) var busy: Set<String> = []
  var error: String?
  private(set) var notice: ConversationNotice?
  var filter = SessionFilter.all
  var selectedProject: String?
  struct ConversationRoute: Hashable {
    let id: String
    var parent: String? = nil
    var tool: String? = nil
    var newSession = false
    var master = false
  }
  var conversationPath: [ConversationRoute] = [] {
    didSet {
      #if DEBUG
      if let id = conversationPath.last?.id, id != oldValue.last?.id { ConversationOpeningMetrics.begin(id) }
      #endif
    }
  }
  var selectedTab = 3
  var conversationOpen: Bool { !conversationPath.isEmpty }
  var currentSessionID: String? { selectedTab == 3 && conversationPath.last?.newSession != true ? (conversationPath.last?.master == true ? masterID : conversationPath.last?.id) : nil }
  let toast = ToastCenter()
  let alerts: SessionAlertCenter
  let catalog: ModelCatalogCache

  @ObservationIgnored let client: OpenCodeClient
  @ObservationIgnored let hub: EventHub
  @ObservationIgnored let drafts: ConversationDrafts
  @ObservationIgnored let reading: ReadingPositionStore
  @ObservationIgnored let expansions = ConversationExpansionMemory()
  @ObservationIgnored private var order = RecentOrder()
  private(set) var chatRoot: String?
  @ObservationIgnored private var reloadPending = false
  @ObservationIgnored private var scheduled: Task<Void, Never>?
  @ObservationIgnored private var lastReloadStarted: ContinuousClock.Instant?
  @ObservationIgnored private var visible: Set<String> = []
  @ObservationIgnored private var previewQueue: [String] = []
  @ObservationIgnored private var previewing: Set<String> = []
  @ObservationIgnored private var previewDirty: Set<String> = []
  @ObservationIgnored private var previewRefresh: Task<Void, Never>?
  @ObservationIgnored private var runningTask: Task<Void, Never>?
  @ObservationIgnored private var runID = UUID()
  @ObservationIgnored private var pruning: Task<Void, Never>?

  init(configuration: ServerConfiguration = .launch(), acceptsLaunchSession: Bool = true) {
    self.acceptsLaunchSession = acceptsLaunchSession
    #if DEBUG
    let client = ScrollFixtures.mode == nil
      ? OpenCodeClient(configuration: configuration) : .scrollFixture(configuration: configuration)
    #else
    let client = OpenCodeClient(configuration: configuration)
    #endif
    self.client = client
    quota = SubscriptionStore(server: configuration.url.absoluteString,
                              client: subscriptionClient(configuration: configuration, client: client))
    catalog = ModelCatalogCache(server: configuration.url.absoluteString)
    drafts = ConversationDrafts(server: configuration.url.absoluteString)
    reading = ReadingPositionStore(server: configuration.url.absoluteString)
    hub = EventHub(client: client)
    alerts = SessionAlertCenter(server: configuration.url.absoluteString)
    #if DEBUG
    if ScrollFixtures.mode != nil {
      let fixture = ScrollFixtures.snapshot
      entries = fixture.entries
      projects = fixture.projects
      preferences = fixture.preferences
      active = Set(entries.enumerated().filter { $0.offset % 17 == 0 }.map { $0.element.session.id })
      previews = Dictionary(uniqueKeysWithValues: entries.map { entry in
        var preview = SessionPreview()
        preview.text = "Resultado sintético com ferramentas, Markdown e código de exemplo."
        preview.activity = "lendo arquivo de exemplo"
        return (entry.session.id, preview)
      })
      order.snapshot(entries, active: active)
      return
    }
    #endif
    pruning = Task {
      await DraftPersistence.pruneMissingSessions(
        server: configuration.url.absoluteString, client: client)
    }
  }

  var rows: [SessionRow] {
    SessionList.rows(
      entries: entries.filter { $0.session.id != masterID }, projects: projects, active: active,
      pins: preferences?.data.pinnedSessions ?? [], muted: preferences?.data.mutedSessions ?? [],
      autoApprove: preferences?.data.settings.autoApprove ?? false, ranks: order.ranks,
      chatRoot: chatRoot)
  }
  var filtered: [SessionRow] {
    #if DEBUG
    if client.configuration.url.host == "127.0.0.1", ConversationOpeningMetrics.enabled,
      let id = ProcessInfo.processInfo.environment["OPENCODE_OPENING_SESSION"] {
      return rows.filter { $0.id == id }
    }
    #endif
    return rows.filter {
      filter.includes($0) && (selectedProject == nil || $0.project?.id == selectedProject)
    }
  }
  var attention: [SessionRow] {
    filtered.filter { $0.state == .permission || $0.state == .question }
  }
  var recent: [SessionRow] { filtered.filter { $0.state != .permission && $0.state != .question } }
  var requestCount: Int { rows.reduce(0) { $0 + $1.requestCount } }
  var selectedProjects: [(directory: String, project: Project)] {
    (preferences?.data.projects["local"]?.projects ?? []).compactMap { selected in
      projects.first {
        $0.canonical == selected.worktree || $0.sandboxes.contains(selected.worktree)
      }.map { (selected.worktree, $0) }
    }
  }
  func directoryLabel(_ session: Session) -> SessionDirectoryLabel? {
    directoryMetadata.label(directory: session.location.directory, chatRoot: chatRoot)
  }
  func permission(_ row: SessionRow) -> PermissionRequest? {
    permissions.first { row.memberIDs.contains($0.sessionID) }
  }
  func question(_ row: SessionRow) -> String {
    forms.first { row.memberIDs.contains($0.sessionID) }?.preview
      ?? "Uma pergunta aguarda sua resposta"
  }

  func run() async {
    #if DEBUG
    if ScrollFixtures.mode != nil {
      guard ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureUpdates") else { return }
      var tick = 0
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let id = entries[(tick % 3) * 17].session.id
        previews[id]?.text = "Resultado sintético atualizado · \(tick)"
        previews[id]?.activity = "lendo arquivo de exemplo · \(tick)"
        tick += 1
      }
      return
    }
    #endif
    if let runningTask { await runningTask.value }
    guard !Task.isCancelled else { return }
    let id = UUID()
    runID = id
    let task = Task { await consumeEvents() }
    runningTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: { task.cancel() }
    if runID == id { runningTask = nil }
  }

  func stop() async {
    runningTask?.cancel()
    await runningTask?.value
    await quota.stop()
    pruning?.cancel()
    await pruning?.value
    await drafts.flush()
    try? reading.flush()
    conversationPath = []
  }

  private func consumeEvents() async {
    quota.start()
    let events = hub.events()
    let connection = Task { await hub.run() }
    var didConnect = false
    defer {
      connection.cancel()
      alerts.disconnect()
    }
    let catalogLoad = Task {
      if let models = try? await client.models(), !Task.isCancelled { catalog.remember(models) }
    }
    defer { catalogLoad.cancel() }
    await reload()
    for await frame in events {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected:
        connected = true
        alerts.connect(at: frame.receivedAt)
        scheduleReload()
        if didConnect { quota.reconnect() }
        didConnect = true
      case .disconnected:
        connected = false
        alerts.disconnect()
      case .update(let event):
        let type = event.type
        let id = event.data.owner
        // The current master is an accessory-only destination, not a global alert shortcut.
        if masterID == nil || id != masterID { await alerts.receive(event, store: self) }
        if type.hasPrefix("session.") || type.hasPrefix("permission.")
          || type.hasPrefix("form.") || type.hasPrefix("rpc.") || type.hasPrefix("project.")
          || type.hasPrefix("worktree.")
        {
          if let id, type.hasPrefix("session.execution.") {
            order.observe(id, running: type == "session.execution.started")
          }
          if type.hasPrefix("session.text.") || type.hasPrefix("session.tool.")
            || type.hasPrefix("session.step.")
          {
            schedulePreviews()
            continue
          }
          scheduleReload()
        }
      }
    }
    connection.cancel()
    await connection.value
    connected = false
    scheduled?.cancel()
    scheduled = nil
    reloadPending = false
    previewRefresh?.cancel()
    previewRefresh = nil
    await quota.stop()
  }

  func reload() async {
    if loading {
      scheduleReload()
      return
    }
    loading = true
    lastReloadStarted = .now
    defer { loading = false }
    do {
      serverVersion = try await client.info().version
      notice = nil
      async let navigation = client.navigation()
      async let prefs = client.preferences()
      async let inventory = client.projects()
      async let running = client.active()
      async let requests = client.permissions()
      async let archives = client.archivedSessions()
      async let chats = try? client.chatRoot()
      async let master: Void = loadMaster()
      let snapshot = try await (navigation, prefs, inventory, running, requests, archives)
      try Task.checkCancellation()
      entries = snapshot.0
      if snapshot.1.revision >= (preferences?.revision ?? -1) { preferences = snapshot.1 }
      projects = snapshot.2
      active = Set(snapshot.3.filter { $0.value.isRunning }.map(\.key))
      permissions = snapshot.4
      archived = snapshot.5.sorted { ($0.time.archived ?? 0) > ($1.time.archived ?? 0) }
      order.snapshot(entries, active: active)
      chatRoot = await chats
      await master
      error = nil
      let pendingDirectories = Set(
        entries.filter { $0.questionAt != nil }.map { $0.session.location.directory })
      var pendingForms: [PendingForm] = []
      for directory in pendingDirectories {
        pendingForms.append(contentsOf: try await client.forms(directory: directory))
      }
      forms = pendingForms
      let metadata = await directoryMetadata.refreshed(
        (entries.map(\.session) + archived).map { $0.location.directory }, using: client)
      try Task.checkCancellation()
      directoryMetadata = metadata
      for id in visible { enqueuePreview(id) }
    } catch {
      if !Task.isCancelled {
        notice = ConversationNotice.classify(error, directory: nil)
        self.error = "Não foi possível atualizar as sessões. \(error.localizedDescription)"
      }
      return
    }
  }

  private func scheduleReload() {
    reloadPending = true
    guard scheduled == nil else { return }
    scheduled = Task {
      while reloadPending && !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(1500)) } catch { break }
        while let lastReloadStarted,
          ContinuousClock.now < lastReloadStarted.advanced(by: .milliseconds(1500))
        {
          do {
            try await ContinuousClock().sleep(
              until: lastReloadStarted.advanced(by: .milliseconds(1500)))
          } catch { return }
        }
        if loading { continue }
        reloadPending = false
        await reload()
      }
      scheduled = nil
    }
  }

  private func schedulePreviews() {
    guard previewRefresh == nil else { return }
    previewRefresh = Task {
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      previewRefresh = nil
      for id in visible { enqueuePreview(id) }
    }
  }

  func show(_ session: Session) {
    #if DEBUG
    if ScrollFixtures.mode != nil { return }
    #endif
    visible.insert(session.id)
    enqueuePreview(session.id)
  }
  func hide(_ session: Session) { visible.remove(session.id) }

  private func enqueuePreview(_ id: String) {
    if previewing.contains(id) {
      previewDirty.insert(id)
      return
    }
    if previewQueue.contains(id) { return }
    previewQueue.append(id)
    drainPreviews()
  }
  private func drainPreviews() {
    while previewing.count < 4, !previewQueue.isEmpty {
      let id = previewQueue.removeFirst()
      previewing.insert(id)
      Task {
        if let preview = try? await client.preview(id) { previews[id] = preview }
        previewing.remove(id)
        if previewDirty.remove(id) != nil { enqueuePreview(id) }
        drainPreviews()
      }
    }
  }

  func pin(_ row: SessionRow) async {
    await perform(row.id, feedback: .light) {
      let keys =
        row.pinned
        ? SessionPreferenceKey.matching(row.id, in: preferences?.data.pinnedSessions ?? [])
        : [SessionPreferenceKey.encode(row.id)]
      for key in keys {
        preferences = try await client.mutate(.pin(session: key, pinned: !row.pinned))
      }
    }
  }
  func mute(_ row: SessionRow) async {
    await perform(row.id, feedback: .light) {
      let keys =
        row.muted
        ? SessionPreferenceKey.matching(row.id, in: preferences?.data.mutedSessions ?? [])
        : [SessionPreferenceKey.encode(row.id)]
      for key in keys {
        preferences = try await client.mutate(.mute(session: key, muted: !row.muted))
      }
    }
  }
  func mutate(_ intent: PreferenceIntent, id: String = "projects") async {
    await perform(id) {
      let removedSelection: Bool
      if case .close(let directory) = intent {
        removedSelection = selectedProjects.contains {
          $0.directory == directory && $0.project.id == selectedProject
        }
      } else {
        removedSelection = false
      }
      preferences = try await client.mutate(intent)
      if removedSelection { selectedProject = nil }
    }
  }
  func touchProject(_ directory: String) async throws {
    preferences = try await client.mutate(.touch(directory: directory))
  }
  func markRead(_ session: Session) async {
    await perform(session.id) { try await client.markViewed(session) }
  }
  func markAllRead() async {
    await perform("read-all") {
      for row in rows where row.unread { try await client.markViewed(row.session) }
    }
  }
  func archive(_ row: SessionRow) async {
    await perform(row.id, feedback: .light) { try await client.archive(row.id) }
  }
  func reply(_ row: SessionRow, allow: Bool) async {
    guard let permission = permission(row) else { return }
    await perform(row.id, feedback: allow ? .success : .warning) {
      try await client.reply(permission, allow: allow)
    }
  }
  private func perform(
    _ id: String, feedback: Haptics.Kind? = nil, action: () async throws -> Void
  ) async {
    guard !busy.contains(id) else { return }
    busy.insert(id)
    defer { busy.remove(id) }
    do {
      try await action()
      if let feedback { Haptics.play(feedback) }
      await reload()
    } catch { self.error = "Não foi possível concluir a ação. \(error.localizedDescription)" }
  }
}
