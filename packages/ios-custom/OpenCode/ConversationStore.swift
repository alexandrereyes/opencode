import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class ConversationStore {
  let id: String
  private(set) var session: Session?
  private(set) var messages: [ConversationMessage] = []
  private(set) var models: [ModelInfo] = []
  private(set) var defaultModel: ModelInfo?
  private(set) var agents: [AgentInfo] = []
  private(set) var providers: [ProviderInfo] = []
  let toast = ToastCenter()
  private(set) var family: FamilySnapshot?
  private(set) var children: [Session] = []
  private(set) var active: Set<String> = []
  private(set) var shells: [ShellInfo] = []
  private(set) var ownerMessages: [ConversationMessage] = []
  private(set) var branch = ""
  private(set) var loading = false
  private(set) var paging = false
  private(set) var hasOlder = true
  private(set) var viewedBoundary: Double?
  private(set) var ready = false
  private(set) var revision = 0
  private(set) var inbox: [InboxItem] = []
  private(set) var preferences: Preferences?
  private(set) var acting: Set<String> = []
  var error: String?
  var revealedToolID: String?
  var sideQuestion: SideQuestionLaunch?
  @ObservationIgnored private let client: OpenCodeClient
  @ObservationIgnored private let hub: EventHub
  @ObservationIgnored private var cursor: String?
  @ObservationIgnored private var refreshing = false
  @ObservationIgnored private var dirty = false
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var batchTask: Task<Void, Never>?
  @ObservationIgnored private var pending: [ConversationEvent] = []
  @ObservationIgnored private var acknowledged: Double?
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var acknowledging = false
  @ObservationIgnored private var replaceHistory = false
  @ObservationIgnored private var snapshotSequence = 0
  @ObservationIgnored private var composerCatalog: ComposerSources?

  init(id: String, client: OpenCodeClient, hub: EventHub) {
    self.id = id
    self.client = client
    self.hub = hub
  }
  var context: Double? { ConversationProjection.context(messages, models: models) }
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
    ContextDetails(messages: messages, models: models, session: session, family: family)
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
      models.first { $0.id == ref?.id && $0.providerID == ref?.providerID }?.name ?? ref?.id,
      ref?.variant == "default" ? nil : ref?.variant,
    ].compactMap { $0 }.joined(separator: " · ")
  }
  func selectedModel(_ draft: ConversationDraft) -> ModelReference? {
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
      let model = selectedModel(draft), session?.parentID == nil
    else { return }
    let agent = draft.agent ?? session?.agent ?? "build"
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
            metadata: draft.editing?.payload.metadata ?? [:]),
          sessionID: id, agent: agent, model: model, replacing: draft.replacing)
        draft.submissionDocument = draft.snapshot
      }
      guard let submission = draft.submission else { return }
      switch ComposerDispatch.resolve(draft.document) {
      case .prompt:
        try await submission.send(using: client)
      case .command(let name, _):
        // Command callbacks have no idempotency key. Never automatically retry them.
        if delivery == .steer {
          try await client.selectAgent(agent, sessionID: id)
          try await client.selectModel(model, sessionID: id)
        }
        try await client.command(name, request: submission.request, sessionID: id)
        if let replacing = submission.replacing {
          try await client.cancelInbox(replacing, sessionID: id)
        }
      case .local(let name):
        guard name == "compact" else { return }
        try await client.compact(id, id: submission.request.id)
      }
      await draft.clear()
      draft.focused = false
      toast.show(
        submission.request.delivery == .queue ? "Mensagem adicionada à fila" : "Mensagem enviada")
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
    guard let session else { return [] }
    if composerCatalog == nil {
      composerCatalog = try await client.composerSources(directory: session.location.directory)
    }
    async let files =
      trigger.character == "@"
      ? client.composerFiles(trigger.query, directory: session.location.directory) : []
    async let sessions = trigger.character == "@" ? client.composerSessions(trigger.query) : []
    return try await composerCatalog?.suggestions(
      trigger, agents: agents, files: files, sessions: sessions,
      current: id, server: client.configuration.url.absoluteString,
      directory: session.location.directory, project: session.projectID) ?? []
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
  func act(_ key: String, success: String, operation: () async throws -> Void) async {
    guard acting.insert(key).inserted else { return }
    defer { acting.remove(key) }
    do {
      try await operation()
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
      permission.id, success: decision == .reject ? "Permissão negada" : "Permissão concedida"
    ) { try await client.reply(permission, decision: decision) }
  }
  func reply(_ form: PendingForm, answer: QuestionReply) async {
    await act(form.id, success: "Resposta enviada") { try await client.reply(form, answer: answer) }
  }
  func dismiss(_ form: PendingForm) async {
    await act(form.id, success: "Pergunta descartada") { try await client.dismiss(form) }
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
    visible = true
    let events = hub.events()
    await refresh()
    for await frame in events {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected: scheduleRefresh()
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
    visible = false
    refreshTask?.cancel()
    refreshTask = nil
    batchTask?.cancel()
    batchTask = nil
  }
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
    guard !refreshing else {
      dirty = true
      return
    }
    refreshing = true
    loading = !ready
    pending.removeAll()
    batchTask?.cancel()
    batchTask = nil
    defer {
      refreshing = false
      loading = false
      snapshotSequence = hub.sequence
    }
    do {
      async let info = client.session(id)
      async let page = client.conversation(id)
      async let running = client.active()
      async let queued = client.inbox(id)
      async let settings = client.preferences()
      let (infoValue, pageValue, runningValue, queueValue, preferencesValue) = try await (
        info, page, running, queued, settings
      )
      try Task.checkCancellation()
      if !ready {
        viewedBoundary = infoValue.time.viewed
        cursor = pageValue.cursor?.next
        hasOlder = !pageValue.data.isEmpty
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
      let directory = infoValue.location.directory
      let nextModels = models.isEmpty ? try await client.models(directory: directory) : models
      let nextDefault = !ready ? try await client.defaultModel(directory: directory) : defaultModel
      let nextAgents = agents.isEmpty ? try await client.agents(directory: directory) : agents
      let nextProviders =
        providers.isEmpty ? try await client.providers(directory: directory) : providers
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
      // Publish the transcript and runtime work snapshot together: the first visible
      // subagent duration/count must use the same authoritative inputs as refreshes.
      session = infoValue
      messages = nextMessages
      active = Set(runningValue.filter { $0.value.isRunning }.map(\.key))
      models = nextModels
      defaultModel = nextDefault
      agents = nextAgents
      providers = nextProviders
      family = snapshots.0
      children = members
      shells = snapshots.1
      branch = snapshots.2.first?.branch ?? URL(fileURLWithPath: directory).lastPathComponent
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
        self.error = "Não foi possível atualizar a conversa. \(error.localizedDescription)"
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
      hasOlder = !page.data.isEmpty && self.cursor != cursor
    } catch { self.error = "Não foi possível carregar o histórico. \(error.localizedDescription)" }
  }
  /// Called after the updated transcript has reached the view, never at request start.
  func presented() async {
    guard let session, !acknowledging,
      let watermark = ConversationProjection.viewedWatermark(
        idle: session.time.idle, viewed: session.time.viewed, acknowledged: acknowledged,
        visible: visible && ready)
    else { return }
    acknowledging = true
    defer { acknowledging = false }
    do {
      try await client.markViewed(session)
      acknowledged = watermark
    } catch {
      if !Task.isCancelled { self.error = "Não foi possível marcar a conversa como lida." }
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
