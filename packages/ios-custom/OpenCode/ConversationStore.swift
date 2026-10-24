import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class ConversationStore {
  let id: String
  private(set) var session: Session?
  private(set) var messages: [ConversationMessage] = []
  var activity = ConversationActivity.empty
  var quoteIndex = ChatQuoteIndex()
  private(set) var dismissedQuotes: Set<String> = []
  private(set) var models: [ModelInfo] = []
  private(set) var defaultModel: ModelInfo?
  private(set) var agents: [AgentInfo] = []
  private(set) var providers: [ProviderInfo] = []
  let toast = ToastCenter()
  let mcps: ConversationMCPStore
  let reversion: ConversationRevert
  private(set) var family: FamilySnapshot?
  private(set) var children: [Session] = []
  private(set) var active: Set<String> = []
  private(set) var shells: [ShellInfo] = []
  private(set) var ownerMessages: [ConversationMessage] = []
  private(set) var branch = ""
  private(set) var located: LocatedDirectory?
  private(set) var loading = false
  private(set) var paging = false
  private(set) var hasOlder = true
  private(set) var submitted = 0
  private(set) var ready = false
  private(set) var hasTranscript = false
  private(set) var revision = 0 {
    didSet { updateActivity() }
  }
  private(set) var inbox: [InboxItem] = []
  private(set) var preferences: Preferences?
  private(set) var acting: Set<String> = []
  var error: String?
  private(set) var notice: ConversationNotice?
  @ObservationIgnored private var renaming: SessionRename?
  var revealedToolID: String?
  var sideQuestion: SideQuestionLaunch?
  var readingRequest: ConversationReadingRequest?
  var expansionValues: [String: Bool] = [:] {
    didSet { expansionMemory?.set(expansionValues, sessionID: id) }
  }
  @ObservationIgnored private let expansionMemory: ConversationExpansionMemory?
  @ObservationIgnored private let quoteDismissals: ChatQuoteDismissals?
  @ObservationIgnored private let client: OpenCodeClient
  @ObservationIgnored private let hub: EventHub
  private let catalog: ModelCatalogCache?
  @ObservationIgnored let usageCache = ContextUsageCache()
  @ObservationIgnored private var cursor: String?
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var dirty = false
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var batchTask: Task<Void, Never>?
  @ObservationIgnored private var pending: [ConversationEvent] = []
  @ObservationIgnored private var requestedView: Double?
  @ObservationIgnored private var replaceHistory = false
  @ObservationIgnored private var snapshotSequence = 0
  @ObservationIgnored private var composerCatalog: ComposerSources?
  private(set) var composerLocation: String?
  private(set) var composerProjectID: String?
  private var composerConfiguration: [NewSessionConfiguration] = []
  private var recentModels: [ModelReference] = []
  @ObservationIgnored var newSessionSubmit: ((ConversationDraft) async -> Void)?
  var isNewSession: Bool { newSessionSubmit != nil }
  var masterMode = false

  func loadNewSession(directory: String, projectID: String, recent: [ModelReference]) async throws {
    ready = false
    composerCatalog = nil
    composerLocation = directory
    composerProjectID = projectID
    async let models = client.models(directory: directory)
    async let agents = client.agents(directory: directory)
    async let providers = client.providers(directory: directory)
    async let preferences = client.preferences()
    async let configuration = client.newSessionConfiguration(directory: directory)
    let value = try await (models, agents, providers, preferences, configuration)
    try Task.checkCancellation()
    self.models = value.0
    self.agents = value.1
    self.providers = value.2
    self.preferences = value.3
    composerConfiguration = value.4
    recentModels = recent
    catalog?.remember(value.0)
    ready = true
  }

  init(
    id: String, client: OpenCodeClient, hub: EventHub,
    expansions: ConversationExpansionMemory? = nil, catalog: ModelCatalogCache? = nil,
    reversion: ConversationRevert? = nil, quoteDismissals: ChatQuoteDismissals? = nil
  ) {
    self.id = id
    self.client = client
    self.reversion = reversion ?? ConversationRevert(client: client)
    mcps = ConversationMCPStore(client: client, toast: toast)
    self.hub = hub
    self.catalog = catalog
    expansionMemory = expansions
    expansionValues = expansions?.values(id) ?? [:]
    self.quoteDismissals = quoteDismissals
    dismissedQuotes = quoteDismissals?.values(id) ?? []
  }
  /// Hides sent quote marks in responses on this device; `metadata.quotes` is never rewritten.
  @discardableResult func dismissQuotes(_ ids: Set<String>) -> Bool {
    guard !ids.isSubset(of: dismissedQuotes) else { return true }
    dismissedQuotes.formUnion(ids)
    guard let quoteDismissals else { return true }
    return (try? quoteDismissals.dismiss(ids, sessionID: id)) != nil
  }
  /// Explicit navigation takes priority over the saved reading position (search/reveal, wave 5).
  func revealMessage(_ id: String, offset: Double = 0, persist: Bool = true) {
    readingRequest = ConversationReadingRequest(messageID: id, offset: offset, persist: persist)
  }
  func rename(_ title: String) async {
    guard renaming == nil, let change = SessionRename(title, current: session?.title) else { return }
    renaming = change
    session?.title = change.title
    defer { renaming = nil }
    do {
      try await client.rename(id, title: change.title)
      toast.show("Sessão renomeada")
    } catch {
      session?.title = change.rollback(current: session?.title)
      toast.show("Não foi possível renomear a sessão.", kind: .error)
    }
  }
  func archive() async -> Bool {
    guard session?.parentID == nil, acting.insert("archive").inserted else { return false }
    defer { acting.remove("archive") }
    do {
      try await client.archive(id)
      Haptics.play(.light)
      return true
    } catch {
      toast.show("Não foi possível arquivar a sessão.", kind: .error)
      return false
    }
  }
  func services() async -> SessionServices {
    guard let directory = session?.location.directory else { return SessionServices() }
    return await client.sessionServices(directory: directory)
  }
  var displayModels: [ModelInfo] { ModelCatalog.merging(models, fallback: catalog?.models ?? []) }
  func usageLimit(_ model: ModelReference?) -> Double? {
    ContextUsage.limit(model, models: models) ?? ContextUsage.limit(model, models: catalog?.models ?? [])
  }
  var isChild: Bool { session?.parentID != nil }
  func selectedAgent(_ draft: ConversationDraft) -> String {
    if masterMode { return "mestra" }
    if isChild { return session?.agent ?? "" }
    if isNewSession {
      return NewSessionProjection.agent(explicit: draft.agent,
        configured: composerConfiguration.compactMap(\.info.default_agent).last, agents: agents)
    }
    return draft.agent ?? session?.agent ?? "build"
  }
  var childAgentName: String {
    if masterMode { return "Mestra" }
    return agents.first { $0.id == session?.agent }?.name ?? session?.agent ?? "Subagente"
  }
  var context: Double? { ConversationProjection.context(messages, models: displayModels) }
  var waiting: Bool { family?.permissions.isEmpty == false || family?.forms.isEmpty == false }
  var working: Bool { active.contains(id) || family?.active.isEmpty == false }
  var executing: Bool { active.contains(id) }
  var queue: [InboxItem] { inbox.filter(\.queuedUser) }
  var canBackground: Bool {
    session?.parentID == nil && executing
      && messages.flatMap(\.tools).contains {
        $0.running && ($0.name == "shell" || $0.name == "subagent") && pendingTool($0) == nil
      }
  }
  var details: ContextDetails {
    ContextDetails(messages: messages, models: displayModels, session: session, family: family)
  }
  var runningWork: [RunningWork] {
    ConversationProjection.runningWork(
      ownerID: session?.parentID ?? id, viewedID: id,
      messages: session?.parentID == nil ? messages : ownerMessages,
      children: children, active: active, shells: shells)
  }
  var runningCount: Int { runningWork.count }
  func providerName(_ id: String) -> String { providers.first { $0.id == id }?.name ?? id }
  func modelLabel(_ ref: ModelReference?) -> String {
    [
      displayModels.first { $0.id == ref?.id && $0.providerID == ref?.providerID }?.name ?? ref?.id,
      ref?.variant == "default" ? nil : ref?.variant,
    ].compactMap { $0 }.joined(separator: " · ")
  }
  func selectedModel(_ draft: ConversationDraft) -> ModelReference? {
    if masterMode, isNewSession { return draft.model }
    if isNewSession {
      let agent = agents.first { $0.id == selectedAgent(draft) }
      var configuredAgent = agent?.model
      if let variant = agent?.variant { configuredAgent?.variant = variant }
      return NewSessionProjection.model(explicit: draft.model, preferences: preferences?.data.models,
        agent: configuredAgent, configured: composerConfiguration.compactMap(\.info.model).last,
        recent: recentModels, models: models)
    }
    if let model = draft.model ?? session?.model { return model }
    if let model = preferences?.data.models?.default {
      return ModelReference(id: model.modelID, providerID: model.providerID, variant: model.variant)
    }
    return defaultModel.map { ModelReference(id: $0.id, providerID: $0.providerID) }
  }
  func pendingTool(_ part: ConversationPart) -> String? {
    ConversationProjection.pendingTool(
      part, permissions: family?.permissions ?? [], forms: family?.forms ?? [])
  }
  func send(_ draft: ConversationDraft, alternate: Bool = false) async {
    if let newSessionSubmit { await newSessionSubmit(draft); return }
    guard await reversion.wait(), ready, notice == nil else { return }
    if let question = SideQuestionRequest.slashQuestion(draft.document) {
      sideQuestion = SideQuestionLaunch(text: question, submit: !question.isEmpty)
      draft.text = NSAttributedString()
      draft.selection = NSRange(location: 0, length: 0)
      draft.focused = false
      await draft.persist()
      return
    }
    guard !draft.sending,
      !draft.importing,
      !draft.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !draft.attachments.isEmpty || !draft.quotes.isEmpty,
      let model = selectedModel(draft), session != nil
    else { return }
    let agent = selectedAgent(draft)
    let delivery = PromptDelivery.choose(
      busy: executing,
      preference: preferences?.data.settings.followUpBehavior ?? .steer, alternate: alternate)
    draft.sending = true
    draft.error = nil
    defer { draft.sending = false }
    do {
      if draft.submissionDocument?.document != draft.document
        || draft.submissionDocument?.attachments != draft.attachments
        || draft.submissionDocument?.quotes != draft.quotes
        || draft.submissionDocument?.revertedContext != draft.revertedContext
        || draft.submission?.model != model
        || draft.submission?.agent != agent || draft.submission == nil
      {
        var attachments: [DeliveredAttachment] = []
        for attachment in draft.attachments {
          if let path = attachment.remotePath {
            attachments.append(.init(attachment: attachment, path: path, inline: nil))
            continue
          }
          toast.show("Enviando anexo \(attachments.count + 1) de \(draft.attachments.count)…")
          let bytes = try await draft.persistence.bytes(attachment)
          attachments.append(
            try await client.deliver(
              attachment, bytes: bytes,
              directory: session?.location.directory ?? "",
              input: models.first { $0.id == model.id && $0.providerID == model.providerID }?
                .capabilities?.input ?? []))
        }
        draft.submission = PromptSubmission(
          request: PromptRequest(
            document: draft.document,
            delivery: delivery, agent: agent, model: model, attachments: attachments,
            quotes: draft.quotes,
            metadata: draft.editing?.payload.metadata ?? draft.revertedContext?.metadata ?? [:],
            contextFiles: draft.revertedContext?.allFiles ?? [], contextText: draft.revertedContext?.text ?? []),
          sessionID: id, agent: agent, model: model, replacing: draft.replacing, keepsAgent: isChild,
          commitsRevert: reversion.boundary(session) != nil)
        draft.submissionDocument = draft.snapshot
      }
      guard let submission = draft.submission else { return }
      switch ComposerDispatch.resolve(draft.document) {
      case .prompt:
        submitted += 1
        try await submission.send(using: client)
      case .command(let name, _):
        submitted += 1
        // Command callbacks have no idempotency key. Never automatically retry them.
        try await submission.applySelection(using: client)
        try await client.command(name, request: submission.request, sessionID: id)
        if let replacing = submission.replacing {
          try await client.cancelInbox(replacing, sessionID: id)
        }
      case .local(let name):
        guard name == "compact" else { return }
        try await client.compact(id, id: submission.request.id)
      }
      // Admission was acknowledged: the carrying bubble now records the quote, so the response mark goes.
      dismissQuotes(Set(ChatQuote.read(submission.request.metadata["quotes"]).map(\.id)))
      draft.didSend()
      await draft.clear()
      catalog?.committed(submission.model)
      Haptics.play(.light)
      draft.focused = false
      toast.show(
        submission.request.delivery == .queue ? "Mensagem adicionada à fila" : "Mensagem enviada")
      if submission.commitsRevert { replaceHistory = true }
      await refresh()
    } catch {
      draft.error =
        "Não foi possível concluir o envio. Seu rascunho foi mantido. \(error.localizedDescription)"
      toast.show("Não foi possível enviar. Seu rascunho foi mantido.", kind: .error)
    }
  }
  func askSideQuestion(_ request: SideQuestionRequest) async throws -> String {
    try await client.sideQuestion(request, sessionID: id)
  }
  func suggestions(_ trigger: ComposerTrigger) async throws -> [ComposerSuggestion] {
    guard let directory = composerLocation ?? session?.location.directory else { return [] }
    if composerCatalog == nil {
      composerCatalog = try await client.composerSources(directory: directory)
    }
    async let files =
      trigger.character == "@"
      ? client.composerFiles(trigger.query, directory: directory) : []
    async let sessions = trigger.character == "@" ? client.composerSessions(trigger.query) : []
    let suggestions = try await composerCatalog?.suggestions(
      trigger, agents: agents, files: files, sessions: sessions,
      current: id, server: client.configuration.url.absoluteString,
      directory: directory, project: composerProjectID ?? session?.projectID) ?? []
    guard isChild else { return suggestions }
    return suggestions.filter {
      !($0.token.kind == .command && $0.token.value == "client" && $0.token.id == "agent")
    }
  }
  func newSessionDocument(_ document: ComposerDocument) async throws -> ComposerDocument {
    guard document.text.hasPrefix("/"), document.validTokens.first?.start != 0,
      let directory = composerLocation else { return document }
    if composerCatalog == nil { composerCatalog = try await client.composerSources(directory: directory) }
    return composerCatalog?.newSessionDocument(document) ?? document
  }
  func importAttachment(_ bytes: Data, name: String, mime: String, draft: ConversationDraft) async {
    do {
      let (data, name, mime) = try await Task.detached(priority: .userInitiated) {
        try AttachmentEncoding.prepare(bytes, name: name, mime: mime)
      }.value
      guard
        draft.attachments.reduce(0, { $0 + $1.size }) + data.count <= AttachmentEncoding.draftLimit
      else {
        throw AttachmentError.tooLarge
      }
      let attachment = DraftAttachment(
        name: URL(fileURLWithPath: name).lastPathComponent, mime: mime, size: data.count)
      try await draft.persistence.store(data, attachment: attachment)
      draft.attachments.append(attachment)
      await draft.persist()
    } catch { toast.show(error.localizedDescription, kind: .error) }
  }
  func act(
    _ key: String, success: String, feedback: Haptics.Kind? = nil,
    operation: () async throws -> Void
  ) async {
    guard acting.insert(key).inserted else { return }
    defer { acting.remove(key) }
    do {
      try await operation()
      if let feedback { Haptics.play(feedback) }
      toast.show(success)
      await refresh()
    } catch {
      let message = "Não foi possível concluir a ação. \(error.localizedDescription)"
      self.error = message
      toast.show(message, kind: .error)
    }
  }
  func promote(_ item: InboxItem) async {
    await act(item.id, success: "Mensagem marcada para enviar agora") {
      try await client.promoteInbox(item.id, sessionID: item.sessionID)
    }
  }
  func cancel(_ item: InboxItem) async {
    await act(item.id, success: "Mensagem removida da fila") {
      try await client.cancelInbox(item.id, sessionID: item.sessionID)
    }
  }
  func stop() async {
    await act("stop", success: "Execução interrompida") {
      try await client.interrupt(id, resume: true)
    }
  }
  func background() async {
    await act("background", success: "Tarefa movida para background") {
      try await client.background(id)
    }
  }
  func stop(_ work: RunningWork) async {
    await act(work.id, success: "Tarefa interrompida") {
      if let child = work.sessionID { try await client.interrupt(child) }
      if let shell = work.shellID, let directory = session?.location.directory {
        try await client.stopShell(shell, directory: directory)
      }
    }
  }
  func reply(_ permission: PermissionRequest, decision: PermissionReply.Decision) async {
    await act(
      permission.id, success: decision == .reject ? "Permissão negada" : "Permissão concedida",
      feedback: decision == .reject ? .warning : .success
    ) { try await client.reply(permission, decision: decision) }
  }
  func reply(_ form: PendingForm, answer: QuestionReply) async {
    await act(form.id, success: "Resposta enviada", feedback: .success) {
      submitted += 1
      try await client.reply(form, answer: answer)
    }
  }
  func dismiss(_ form: PendingForm) async {
    await act(form.id, success: "Pergunta descartada", feedback: .warning) {
      try await client.dismiss(form)
    }
  }
  func updateModels(_ intents: [PreferenceIntent], success: String) async {
    guard acting.insert("models").inserted else { return }
    defer { acting.remove("models") }
    do {
      for intent in intents {
        let updated = try await client.mutate(intent)
        if updated.revision >= (preferences?.revision ?? -1) { preferences = updated }
      }
      toast.show(success)
    } catch {
      toast.show(
        "Não foi possível atualizar os modelos. \(error.localizedDescription)", kind: .error)
    }
  }
  func responseText(endingAt id: String) -> String {
    guard let end = messages.firstIndex(where: { $0.id == id }) else { return "" }
    let start = messages[..<end].lastIndex(where: { $0.type == "user" }).map { $0 + 1 } ?? 0
    return messages[start...end].map(\.responseText).filter { !$0.isEmpty }.joined(
      separator: "\n\n")
  }
  func run() async {
    #if DEBUG
    if ScrollFixtures.mode != nil {
      let fixture = ScrollFixtures.snapshot
      session = fixture.entries.first?.session
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureChild") {
        var value = try! JSONDecoder().decode([String: JSONValue].self,
          from: JSONEncoder().encode(fixture.entries[0].session))
        value["parentID"] = .string("ses_fixture_parent")
        session = try! JSONDecoder().decode(Session.self, from: JSONEncoder().encode(value))
      }
      messages = fixture.messages
      models = fixture.models
      branch = "exemplo-sintetico"
      hasOlder = false
      hasTranscript = true
      ready = true
      revision += 1
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureMenuUpdates") {
        let source = messages
        let updating = source.last { $0.type == "assistant" && !$0.responseText.isEmpty }?.id
        var tick = 0
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          branch = "fixture-menu-\(tick)"
          if !ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureMenuHeaderOnly") {
            messages = source.map { message in
              guard message.id == updating,
                let part = message.content?.lastIndex(where: { $0.type == "text" }) else { return message }
              var updated = message
              updated.content?[part].text = (message.content?[part].text ?? "") + "\n\nEstado sintético \(tick)."
              return updated
            }
            revision += 1
          }
          tick += 1
        }
      }
      return
    }
    #endif
    let events = hub.events()
    await refresh()
    for await frame in events {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected: scheduleRefresh()
      case .disconnected: break
      case .update(let event):
        let ids = Set([id, session?.parentID].compactMap { $0 } + children.map(\.id))
        guard event.data.owner.map(ids.contains) == true || event.type.hasPrefix("rpc.") else {
          continue
        }
        if event.type.hasPrefix("session.revert.") { replaceHistory = true }
        // Snapshot and stream race: buffered deltas may already be in the snapshot.
        // Never append them twice; revalidate once more to cover the read's in-flight window.
        if refreshing || frame.sequence <= snapshotSequence {
          scheduleRefresh()
          continue
        }
        if event.data.owner == id {
          pending.append(event)
          scheduleBatch()
        }
        if !event.type.hasSuffix(".delta") && !event.type.hasSuffix(".progress") {
          scheduleRefresh()
        }
      }
    }
    refreshTask?.cancel()
    refreshTask = nil
    batchTask?.cancel()
    batchTask = nil
  }
  #if DEBUG
  func growScrollFixture(_ iteration: Int) {
    guard ScrollFixtures.mode == "conversation" else { return }
    let rows = messages.filter { $0.type == "assistant" }.suffix(3).map(\.id)
    guard !rows.isEmpty else { return }
    let id = rows[min(iteration, rows.count - 1)]
    messages = messages.map { message in
      guard message.id == id, let part = message.content?.lastIndex(where: { $0.type == "text" }) else { return message }
      var updated = message
      updated.content?[part].text = (message.content?[part].text ?? "")
        + "\n\n- [ ] Verificação \(iteration): altura variável durante o acompanhamento do fim."
      return updated
    }
    revision += 1
  }
  #endif
  private func scheduleBatch() {
    guard batchTask == nil else { return }
    batchTask = Task {
      do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
      let events = pending
      pending.removeAll()
      batchTask = nil
      for event in events {
        if !ConversationReducer.apply(event, to: &messages) { scheduleRefresh() }
      }
      revision += 1
    }
  }
  private func scheduleRefresh() {
    dirty = true
    guard refreshTask == nil else { return }
    refreshTask = Task {
      while dirty && !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        dirty = false
        await refresh()
      }
      refreshTask = nil
    }
  }
  func refresh() async {
    #if DEBUG
    ConversationOpeningMetrics.mark("refresh", id: id)
    #endif
    guard !refreshing else {
      dirty = true
      return
    }
    refreshing = true
    loading = !hasTranscript
    pending.removeAll()
    batchTask?.cancel()
    batchTask = nil
    defer {
      refreshing = false
      loading = false
      snapshotSequence = hub.sequence
    }
    do {
      async let health = client.info()
      async let info = client.session(id)
      async let page = client.conversation(id)
      async let running = client.active()
      async let queued = client.inbox(id)
      async let settings = client.preferences()
      _ = try await health
      #if DEBUG
      ConversationOpeningMetrics.mark("health", id: id)
      #endif
      let infoValue = try await info
      try Task.checkCancellation()
      session = infoValue
      reversion.reconcile(infoValue)
      if let renaming { session?.title = renaming.title }
      let (pageValue, runningValue) = try await (page, running)
      try Task.checkCancellation()
      if !hasTranscript {
        #if DEBUG
        ConversationOpeningMetrics.mark("tail", id: id)
        #endif
        cursor = pageValue.cursor?.next
        hasOlder = !pageValue.data.isEmpty && cursor != nil
      }
      var nextMessages = ConversationProjection.merge(messages, page: pageValue.data.reversed())
      if replaceHistory {
        let count = messages.count
        var replacement = Array(pageValue.data.reversed())
        var next = pageValue.cursor?.next
        while replacement.count < count, let current = next {
          let older = try await client.conversation(id, cursor: current)
          if older.data.isEmpty {
            next = nil
            break
          }
          replacement = ConversationProjection.merge(
            replacement, page: older.data.reversed(), older: true)
          next = older.cursor?.next
          if next == current { break }
        }
        nextMessages = replacement
        cursor = next
        hasOlder = next != nil
        replaceHistory = false
      }
      // Reopening a staged Session must load its boundary, not offer full redo from a hidden tail page.
      while let boundary = infoValue.revert?.messageID, let current = cursor,
        !nextMessages.contains(where: { $0.id == boundary })
          || !nextMessages.contains(where: { $0.type == "user" && $0.id < boundary }) {
        let older = try await client.conversation(id, cursor: current)
        nextMessages = ConversationProjection.merge(nextMessages, page: older.data.reversed(), older: true)
        cursor = older.data.isEmpty || older.cursor?.next == current ? nil : older.cursor?.next
        hasOlder = cursor != nil
      }
      let directory = infoValue.location.directory
      active = Set(runningValue.filter { $0.value.isRunning }.map(\.key))
      messages = nextMessages
      reversion.reconcile(infoValue, messages: nextMessages)
      hasTranscript = true
      loading = false
      revision += 1
      error = nil
      #if DEBUG
      ConversationOpeningMetrics.mark("published", id: id)
      #endif
      // First content does not depend on Location boot, catalogs or family.
      // Restoration and sending still wait for the stable runtime projection.
      if (try? await client.directoryAvailable(directory)) == false {
        ready = true
        revision += 1
        notice = .missingDirectory(directory)
        error = nil
        return
      }
      notice = nil
      #if DEBUG
      ConversationOpeningMetrics.mark("directory", id: id)
      #endif
      async let nextModels = models.isEmpty ? client.models(directory: directory) : models
      async let nextDefault = defaultModel == nil ? client.defaultModel(directory: directory) : defaultModel
      async let nextAgents = agents.isEmpty ? client.agents(directory: directory) : agents
      async let nextProviders =
        providers.isEmpty ? client.providers(directory: directory) : providers
      async let familyValue = client.family(id)
      async let shellValue = client.shells(directory: directory)
      async let located = client.locate([directory])
      let snapshots = try await (familyValue, shellValue, located)
      var members: [Session] = []
      var after: String?
      repeat {
        let page = try await client.familyPage(infoValue.parentID ?? id, after: after)
        members.append(contentsOf: page.data)
        if page.next == after { break }
        after = page.next
      } while after != nil
      let parentMessages =
        if let parent = infoValue.parentID {
          try await client.conversation(parent).data.reversed().map { $0 }
        } else { [ConversationMessage]() }
      let (queueValue, preferencesValue) = try await (queued, settings)
      let catalogs = try await (nextModels, nextDefault, nextAgents, nextProviders)
      try Task.checkCancellation()
      #if DEBUG
      ConversationOpeningMetrics.mark("catalogs", id: id)
      ConversationOpeningMetrics.mark("runtime", id: id)
      #endif
      // Never republish the earlier tail here: search/reading may have prepended
      // older pages while these independent runtime reads were in flight.
      models = catalogs.0
      catalog?.remember(models)
      defaultModel = catalogs.1
      agents = catalogs.2
      providers = catalogs.3
      family = snapshots.0
      children = members
      shells = snapshots.1
      branch = snapshots.2.first?.branch ?? URL(fileURLWithPath: directory).lastPathComponent
      self.located = snapshots.2.first
      ownerMessages = parentMessages
      inbox = queueValue
      if preferencesValue.revision >= (preferences?.revision ?? -1) {
        preferences = preferencesValue
      }
      ready = true
      revision += 1
      error = nil
    } catch {
      if !Task.isCancelled {
        if let notice = ConversationNotice.classify(error, directory: session?.location.directory) {
          if case .missingDirectory = notice, hasTranscript {
            ready = true
            revision += 1
          }
          self.notice = notice
          self.error = nil
        } else {
          self.error = "Não foi possível atualizar a conversa. \(error.localizedDescription)"
        }
      }
    }
  }
  func older() async {
    guard !paging, hasOlder, let cursor else { return }
    paging = true
    defer { paging = false }
    do {
      let page = try await client.conversation(id, cursor: cursor)
      try Task.checkCancellation()
      messages = ConversationProjection.merge(messages, page: page.data.reversed(), older: true)
      self.cursor = page.cursor?.next
      hasOlder = !page.data.isEmpty && self.cursor != nil && self.cursor != cursor
      revision += 1
    } catch {
      if !Task.isCancelled {
        self.error = "Não foi possível carregar o histórico. \(error.localizedDescription)"
      }
    }
  }
  /// Route acknowledgement is independent of transcript layout, paging and catalogs.
  func presented() async {
    guard let session,
      let watermark = ConversationProjection.viewedWatermark(
        idle: session.time.idle, viewed: session.time.viewed, acknowledged: requestedView,
        visible: true)
    else { return }
    let previous = requestedView
    requestedView = watermark
    do {
      try await client.markViewed(session)
    } catch {
      if requestedView == watermark { requestedView = previous }
    }
  }
  func shellOutput(_ part: ConversationPart) async throws -> String? {
    guard let directory = session?.location.directory,
      let shellID = part.metadata["shellID"]?.string
        ?? shells.first(where: {
          $0.metadata?["sessionID"]?.string == id && $0.command == part.input["command"]?.string
        })?.id
    else { return nil }
    let output = try await client.shellOutput(shellID, directory: directory)
    if output.size > 65536 {
      return try await client.shellOutput(
        shellID, directory: directory, cursor: output.size - 65536
      ).output
    }
    return output.output
  }
}
