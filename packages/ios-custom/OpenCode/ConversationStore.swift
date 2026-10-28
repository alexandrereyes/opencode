import Foundation
import Observation
import OpenCodeKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers

@MainActor @Observable final class ConversationStore {
  let id: String
  private(set) var session: Session?
  private(set) var messages: [ConversationMessage] = []
  var activity = ConversationActivity.empty
  var quoteIndex = ChatQuoteIndex()
  private var localDismissed: Set<String> = []
  /// Sent quote marks hidden in responses: the server's list (`custom.quotes`) or this device's.
  var dismissedQuotes: Set<String> { quotes.dismissed ?? localDismissed }
  /// Pending quotes on the server, when it has `custom.quotes`.
  let quotes: QuoteSync
  private(set) var models: [ModelInfo] = []
  private(set) var defaultModel: ModelInfo?
  private(set) var agents: [AgentInfo] = []
  private(set) var providers: [ProviderInfo] = []
  let toast = ToastCenter()
  /// Reading place and presentation choices kept while the conversation stays in the registry.
  let memory = TranscriptMemory()
  /// Rows reach it only from the footer's action, so reading never observes the transcript.
  let readAloud = ConversationReadAloud()
  let mcps: ConversationMCPStore
  let reversion: ConversationRevert
  private(set) var family: FamilySnapshot?
  private(set) var children: [Session] = []
  /// Simulators, emulators and browsers this conversation's family used (`custom.resources`).
  private(set) var resources: [SessionResource] = []
  @ObservationIgnored private var resourcesTask: Task<Void, Never>?
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
  /// Optimistic prompt rows shown from the tap until a refresh after admission observes them.
  private(set) var outbox: [InboxItem] = []
  @ObservationIgnored private var acknowledged: Set<String> = []
  private(set) var preferences: Preferences?
  private(set) var acting: Set<String> = []
  var error: String?
  private(set) var notice: ConversationNotice?
  /// Other worktrees and descendants left in the vanished directory, for the notice's move actions.
  private(set) var relocationWorktrees: [WorktreeChoice] = []
  private(set) var strandedChildren: [Session] = []
  private(set) var relocating = false
  @ObservationIgnored private var renaming: SessionRename?
  var revealedToolID: String?
  /// A tool to reveal once the conversation is visible again, set from the agents screen.
  var toolRequest: String?
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
  @ObservationIgnored private var fixtureHistory: [ConversationMessage] = []
  /// A finger or fling owns the transcript; streamed deltas then publish at a calmer cadence.
  @ObservationIgnored var scrolling = false
  @ObservationIgnored private var refreshing = false
  /// Each visible screen runs one event loop; a screen leaving late must not stop its successor's.
  @ObservationIgnored private var generation = 0
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
  /// A new session's app MCPs come from its chips; `intent` when they only record intent for a
  /// Location that does not exist yet. Nil while they are unknown.
  @ObservationIgnored var newSessionApps: (@MainActor () -> (enabled: [String], intent: Bool)?)?
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
    reversion: ConversationRevert? = nil, quoteDismissals: ChatQuoteDismissals? = nil,
    quoteModes: QuoteModes? = nil, draft: ConversationDraft? = nil
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
    localDismissed = quoteDismissals?.values(id) ?? []
    quotes = QuoteSync(sessionID: id, client: client, modes: quoteModes ?? QuoteModes(), dismissals: quoteDismissals)
    quotes.draft = draft
    mcps.changed = { [weak self] in self?.prepareApps() }
    quotes.failed = { [weak self] message in self?.toast.show(message, kind: .error) }
  }
  /// Hides sent quote marks in responses; `metadata.quotes` is never rewritten. In server mode the
  /// list is shared with the web, otherwise it stays on this device.
  @discardableResult func dismissQuotes(_ ids: Set<String>) -> Bool {
    guard !ids.isSubset(of: dismissedQuotes) else { return true }
    if quotes.server {
      Task {
        if await !quotes.dismiss(ids) {
          toast.show("A marcação foi removida, mas não pôde ser salva no servidor.", kind: .error)
        }
      }
      return true
    }
    localDismissed.formUnion(ids)
    guard let quoteDismissals else { return true }
    return (try? quoteDismissals.dismiss(ids, sessionID: id)) != nil
  }
  /// Opening, reconnecting and returning to the foreground re-probe and relist the pending quotes.
  func syncQuotes() {
    guard let directory = session?.location.directory, let draft = quotes.draft else { return }
    quotes.directory = directory
    draft.quoteSync = quotes
    Task { await quotes.start() }
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
    if await !client.rename(id, to: change, toast: toast) {
      session?.title = change.rollback(current: session?.title)
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
  func loadRelocation(_ project: Project) async {
    guard case .missingDirectory(let missing) = notice else { return }
    async let worktrees = try? client.relocationWorktrees(project: project, missing: missing)
    async let stranded = try? client.strandedDescendants(id, missing: missing)
    relocationWorktrees = await worktrees ?? []
    strandedChildren = await stranded ?? []
  }
  /// Only on a tap: moves this Session, and optionally its stranded descendants, then reloads it in place.
  func relocate(to directory: String, children: Bool) async {
    guard !relocating, !executing, case .missingDirectory = notice else { return }
    relocating = true
    defer { relocating = false }
    do {
      try await client.moveSession(id, directory: directory)
    } catch {
      toast.show("Não foi possível mover a sessão. \(error.localizedDescription)", kind: .error)
      return
    }
    var failed = 0
    for child in children ? strandedChildren : [] {
      do { try await client.moveSession(child.id, directory: directory) } catch { failed += 1 }
    }
    relocationWorktrees = []
    strandedChildren = []
    await refresh()
    if failed > 0 {
      toast.show("A sessão foi movida, mas \(failed) subsessão(ões) não puderam ser movidas.", kind: .error)
      return
    }
    Haptics.play(.success)
  }
  func services() async -> SessionServices {
    guard let session else { return SessionServices() }
    return await client.sessionServices(sessionID: session.id, directory: session.location.directory)
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
  /// Server inbox plus optimistic admissions awaiting their echo.
  var pendingInbox: [InboxItem] {
    let admitted = Set(inbox.map(\.id))
    return inbox + outbox.filter { !admitted.contains($0.id) }
  }
  var queue: [InboxItem] { pendingInbox.filter(\.queuedUser) }
  /// Inbox actions wait for the server to know the item; optimistic rows are not admitted yet.
  func actionable(_ item: InboxItem) -> Bool {
    !acting.contains(item.id) && inbox.contains { $0.id == item.id }
  }
  /// Undelivered steers render below the transcript, like the web timeline's pending inputs.
  /// They are never hidden history: a reset cancels earlier pending input, and a new prompt commits
  /// the staged boundary before admission, so its bubble shows from the tap.
  var pendingSteers: [InboxItem] { PendingInputs.steers(pendingInbox, messages: messages) }
  /// Like the web, child sessions show their pending steers without pending actions or styling.
  func pendingStatus(_ item: InboxItem) -> PendingInputStatus? {
    guard !isChild else { return nil }
    return PendingInputs.status(item, inbox: pendingInbox, messages: messages, running: executing)
  }
  var canBackground: Bool {
    session?.parentID == nil && executing
      && messages.flatMap(\.tools).contains {
        $0.running && ($0.name == "shell" || $0.name == "subagent") && pendingTool($0) == nil
      }
  }
  var details: ContextDetails {
    ContextDetails(messages: messages, models: displayModels, session: session, family: family)
  }
  var work: [SessionWork] {
    ConversationProjection.work(
      ownerID: session?.parentID ?? id, viewedID: id,
      messages: session?.parentID == nil ? messages : ownerMessages,
      children: children, active: active, shells: shells)
  }
  var runningCount: Int { work.filter(\.running).count }
  var runningAgents: Int { work.filter { $0.kind == .agent && $0.running }.count }
  /// The child session of one of this conversation's `subagent` calls, including a reloaded running call
  /// whose part does not carry the child's ID.
  func subagentChild(_ part: ConversationPart) -> String? {
    if let child = part.childID { return child }
    guard part.name == "subagent", let id = part.id else { return nil }
    return ConversationProjection.subagentLinks(
      tools: messages.flatMap(\.tools), children: children, ownerID: self.id)[id]
  }
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
    #if os(macOS)
    let quotes = draft.quoteSync ?? self.quotes
    #endif
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
    let snapshot = draft.snapshot
    let editing = draft.editing
    let dispatch = ComposerDispatch.resolve(snapshot.document)
    let reusable = draft.submission.flatMap { submission in
      draft.submissionDocument?.document == snapshot.document
        && draft.submissionDocument?.attachments == snapshot.attachments
        && draft.submissionDocument?.quotes == snapshot.quotes
        && draft.submissionDocument?.revertedContext == snapshot.revertedContext
        && submission.model == model && submission.agent == agent ? submission : nil
    }
    let requestID = reusable?.request.id ?? PromptRequest.newID()
    func request(_ attachments: [DeliveredAttachment]) -> PromptRequest {
      PromptRequest(
        id: requestID, document: snapshot.document,
        delivery: delivery, agent: agent, model: model, attachments: attachments,
        quotes: snapshot.quotes,
        metadata: editing?.payload.metadata ?? snapshot.revertedContext?.metadata ?? [:],
        contextFiles: snapshot.revertedContext?.allFiles ?? [], contextText: snapshot.revertedContext?.text ?? [])
    }
    // Like the web's optimistic admission, the bubble and an empty composer appear on tap; the
    // admission ID is minted first, so the server echo reconciles this same row.
    var optimistic: InboxItem?
    if case .prompt = dispatch, !pendingInbox.contains(where: { $0.id == requestID }),
      !messages.contains(where: { $0.id == requestID }) {
      let item = InboxItem(
        optimistic: reusable?.request ?? request([]), sessionID: id,
        attachments: snapshot.attachments.filter { $0.quoteID == nil }.map(\.name),
        created: Date.now.timeIntervalSince1970 * 1000)
      optimistic = item
      outbox.append(item)
      draft.holdsPersistence = true
      draft.text = NSAttributedString()
      draft.attachments = []
      draft.quotes = []
      draft.revertedContext = nil
      draft.editing = nil
      draft.replacing = nil
      draft.selection = NSRange(location: 0, length: 0)
      submitted += 1
      revision += 1
    }
    defer { draft.holdsPersistence = false }
    do {
      let submission: PromptSubmission
      if let reusable {
        submission = reusable
      } else {
        var attachments: [DeliveredAttachment] = []
        // Server-stored comment attachments are fetched once, then cached by content ID.
        try await quotes.download(snapshot.attachments)
        for attachment in snapshot.attachments {
          if let path = attachment.remotePath {
            attachments.append(.init(attachment: attachment, path: path, inline: nil))
            continue
          }
          toast.show("Enviando anexo \(attachments.count + 1) de \(snapshot.attachments.count)…")
          let bytes = try await draft.persistence.bytes(attachment)
          attachments.append(
            try await client.deliver(
              attachment, bytes: bytes,
              directory: session?.location.directory ?? "",
              input: models.first { $0.id == model.id && $0.providerID == model.providerID }?
                .capabilities?.input ?? []))
        }
        submission = PromptSubmission(
          request: request(attachments),
          sessionID: id, agent: agent, model: model, replacing: snapshot.replacing, keepsAgent: isChild,
          commitsRevert: reversion.boundary(session) != nil)
        draft.submission = submission
        draft.submissionDocument = snapshot
      }
      switch dispatch {
      case .prompt:
        if optimistic == nil { submitted += 1 }
        try await submission.send(using: client)
        acknowledged.insert(submission.request.id)
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
      let sent = ChatQuote.read(submission.request.metadata["quotes"]).map(\.id)
      dismissQuotes(Set(sent))
      draft.didSend()
      await draft.clear()
      // Only the IDs that went out: a quote added meanwhile on another device stays pending.
      await quotes.sent(sent)
      catalog?.committed(submission.model)
      Haptics.play(.light)
      draft.focused = false
      if submission.commitsRevert { replaceHistory = true }
      await refresh()
    } catch {
      if let optimistic {
        // Like the web, retract the unacknowledged row and return the prompt to the composer.
        outbox.removeAll { $0.id == optimistic.id }
        revision += 1
        draft.text = snapshot.document.attributed
        draft.attachments = snapshot.attachments
        draft.quotes = snapshot.quotes
        draft.revertedContext = snapshot.revertedContext
        draft.editing = editing
        draft.replacing = snapshot.replacing
        draft.selection = NSRange(location: snapshot.document.editorOffset(snapshot.cursor), length: 0)
        draft.holdsPersistence = false
        await draft.persist()
      }
      draft.error =
        "Não foi possível concluir o envio. Seu rascunho foi mantido. \(error.localizedDescription)"
      toast.show("Não foi possível enviar. Seu rascunho foi mantido.", kind: .error)
    }
    // Listings that arrived while the optimistic send owned the composer were deferred.
    Task { await quotes.reload() }
  }
  func askSideQuestion(_ request: SideQuestionRequest) async throws -> String {
    #if DEBUG
    if SideQuestionFixture.enabled { return try await SideQuestionFixture.answer() }
    #endif
    return try await client.sideQuestion(request, sessionID: id)
  }
  /// Where app mentions come from, without waiting for the Location's MCP list.
  var appScope: ComposerAppScope? {
    guard let directory = composerLocation ?? session?.location.directory else { return nil }
    let server = client.configuration.url.absoluteString
    if let newSessionApps {
      let value = newSessionApps()
      return .init(
        server: server, directory: directory, enabled: value?.enabled, intent: value?.intent ?? false)
    }
    let known = mcps.directory == directory && !mcps.failed && (!mcps.servers.isEmpty || !mcps.loading)
    return .init(
      server: server, directory: directory,
      enabled: known ? ComposerAppScope.enabled(mcps.servers) : nil)
  }
  /// Lists app mentions ahead of `@` once the enabled app MCPs are known; `open` lists even before.
  func prepareApps(open: Bool = false) {
    guard let appScope else { return }
    ComposerAppMentions.shared.prepare(appScope, client: client, open: open)
  }
  func suggestions(_ trigger: ComposerTrigger) async throws -> [ComposerSuggestion] {
    guard let directory = composerLocation ?? session?.location.directory else { return [] }
    if trigger.character == "@" { prepareApps(open: true) }
    if composerCatalog == nil {
      composerCatalog = try await client.composerSources(directory: directory)
    }
    async let files =
      trigger.character == "&"
      ? client.composerFiles(trigger.query, directory: directory) : []
    async let sessions = trigger.character == "@" ? client.composerSessions(trigger.query) : []
    let apps = trigger.character == "@" ? appScope.map(ComposerAppMentions.shared.apps) ?? [] : []
    let suggestions = try await composerCatalog?.suggestions(
      trigger, agents: agents, files: files, sessions: sessions, apps: apps,
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
  func importAttachment(
    _ bytes: Data, name: String, mime: String, draft: ConversationDraft, reservedBytes: Int = 0
  ) async {
    do {
      let (data, name, mime) = try await Task.detached(priority: .userInitiated) {
        try AttachmentEncoding.prepare(bytes, name: name, mime: mime)
      }.value
      guard
        reservedBytes + draft.attachments.reduce(0, { $0 + $1.size }) + data.count
          <= AttachmentEncoding.draftLimit
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
  /// Images pasted or dropped into the editor, imported like the "+" menu's photos.
  func importImages(_ providers: [NSItemProvider], draft: ConversationDraft, reservedBytes: Int = 0) async {
    guard !providers.isEmpty else { return }
    draft.importing = true
    defer { draft.importing = false }
    for provider in providers {
      do {
        let (data, type) = try await Self.imageData(provider)
        await importAttachment(
          data, name: "Imagem-\(UUID().uuidString.prefix(6)).\(type.preferredFilenameExtension ?? "png")",
          mime: type.preferredMIMEType ?? "image/png", draft: draft, reservedBytes: reservedBytes)
      } catch { toast.show("Não foi possível colar a imagem.", kind: .error) }
    }
  }
  private static func imageData(_ provider: NSItemProvider) async throws -> (Data, UTType) {
    let type = provider.registeredContentTypes.first { $0.conforms(to: .image) && $0.preferredMIMEType != nil }
    if let type {
      return (try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadDataRepresentation(for: type) { data, error in
          if let data { return continuation.resume(returning: data) }
          continuation.resume(throwing: error ?? AttachmentError.image)
        }
      }, type)
    }
    #if os(iOS)
    // A bare UIImage (for example from an attributed insertion) has no file type of its own.
    let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
      _ = provider.loadObject(ofClass: UIImage.self) { object, error in
        if let image = object as? UIImage { return continuation.resume(returning: image) }
        continuation.resume(throwing: error ?? AttachmentError.image)
      }
    }
    guard let data = image.pngData() else { throw AttachmentError.image }
    #else
    let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
      _ = provider.loadObject(ofClass: NSImage.self) { object, error in
        if let image = object as? NSImage { return continuation.resume(returning: image) }
        continuation.resume(throwing: error ?? AttachmentError.image)
      }
    }
    guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { throw AttachmentError.image }
    #endif
    return (data, .png)
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
  func moveToQueue(_ item: InboxItem) async {
    await act(item.id, success: "Mensagem movida para a fila") {
      try await client.updateInbox(item.id, sessionID: item.sessionID, delivery: .queue)
    }
  }
  func deletePending(_ item: InboxItem) async {
    await act(item.id, success: "Mensagem pendente excluída") {
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
  func stop(_ work: SessionWork) async {
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
  /// The footer's play: reads the answer that ends at this message.
  func readAloudResponse(endingAt id: String) {
    guard let response = ReadAloud.response(messages, endingAt: id, sessionID: self.id), !response.text.isEmpty
    else { return }
    readAloud.read(response, title: session?.title ?? "Resposta", client: client)
  }
  func responseText(endingAt id: String) -> String {
    ReadAloud.response(messages, endingAt: id, sessionID: self.id)?.text ?? ""
  }
  func run() async {
    #if DEBUG
    if ScrollFixtures.mode != nil {
      let arguments = ProcessInfo.processInfo.arguments
      // A retained conversation keeps its loaded pages, like a live one that only merges the tail.
      if !hasTranscript { await loadScrollFixture() }
      // Reference capture only: avoid XCTest's intermittent AX stall while typing a slash command.
      if ScrollFixtures.mode == "catalog", arguments.contains("-OpenCodeCatalogSideQuestion") {
        sideQuestion = SideQuestionLaunch(text: "Qual deve ser o primeiro passo?", submit: true)
      }
      if let index = arguments.firstIndex(of: "-OpenCodeFixtureStream"), arguments.indices.contains(index + 1),
        let interval = Int(arguments[index + 1])
      {
        await streamScrollFixture(every: interval)
        return
      }
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
    generation += 1
    let current = generation
    let events = hub.events()
    await refresh()
    scheduleResources()
    syncQuotes()
    for await frame in events {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected:
        // Reconnection (including after the background) merges the tail; it never rebuilds the transcript.
        scheduleRefresh()
        scheduleResources()
        syncQuotes()
      case .disconnected: break
      case .update(let event) where event.type == QuoteServer.updated:
        // Quote edits are per Session and revision: never a transcript refresh, and never another Session's.
        if event.data.sessionID == id, let revision = event.data.revision { quotes.updated(revision: revision) }
      case .update(let event) where event.type == OpenCodeClient.resourcesChangedEvent:
        scheduleResources()
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
    guard generation == current else { return }
    refreshTask?.cancel()
    refreshTask = nil
    batchTask?.cancel()
    batchTask = nil
    resourcesTask?.cancel()
    resourcesTask = nil
  }
  #if DEBUG
  private func loadScrollFixture() async {
    let fixture = ScrollFixtures.snapshot
    let arguments = ProcessInfo.processInfo.arguments
    session = fixture.entries.first?.session
    if arguments.contains("-OpenCodeFixtureChild") {
      var value = try! JSONDecoder().decode([String: JSONValue].self,
        from: JSONEncoder().encode(fixture.entries[0].session))
      value["parentID"] = .string("ses_fixture_parent")
      session = try! JSONDecoder().decode(Session.self, from: JSONEncoder().encode(value))
    }
    let paged = arguments.contains("-OpenCodeFixturePaged")
    // Paged fixtures expose only the newest page; `older()` prepends the rest like a cursor read.
    fixtureHistory = paged ? Array(fixture.messages.dropLast(Self.fixturePage)) : []
    messages = paged ? Array(fixture.messages.suffix(Self.fixturePage)) : fixture.messages + ScrollFixtures.arrivals
    if ScrollFixtures.reentry == "memory" {
      // Distinct text per conversation, so retained conversations share no strings or parses.
      messages = messages.map { message in
        var copy = message
        copy.content = message.content?.map { part in
          var part = part
          if part.type == "text" { part.text = (part.text ?? "") + " (" + id + ")" }
          return part
        }
        return copy
      }
    }
    ScrollFixtures.conversation = self
    models = fixture.models
    #if os(iOS)
    if ScrollFixtures.mode == "catalog" {
      resources = ScreenCatalogFixture.resources
      children = ScreenCatalogFixture.children
      shells = arguments.contains("-OpenCodeCatalogNoScripts") ? [] : ScreenCatalogFixture.scripts
      active = ScreenCatalogFixture.active
      preferences = fixture.preferences
      providers = [.init(id: "fixture", name: "Modelos de demonstração")]
      agents = (try? await client.agents(directory: "/Projetos/exemplo-0")) ?? []
      await mcps.load(directory: "/Projetos/exemplo-0")
      // Mounting can cancel the view's first load after it sets the directory but before it fills the chips.
      await mcps.refresh()
      inbox = ScreenCatalogFixture.inbox
    }
    #endif
    branch = "exemplo-sintetico"
    hasOlder = !fixtureHistory.isEmpty
    hasTranscript = true
    ready = true
    revision += 1
  }
  #endif
  /// Returning to the foreground merges the tail at once instead of waiting for the event stream to notice a
  /// connection the suspension may have half-closed. The loop keeps running; an unchanged tail publishes nothing.
  func revalidate() {
    #if DEBUG
    if ScrollFixtures.mode != nil { return }
    #endif
    guard hasTranscript else { return }
    scheduleRefresh()
  }
  /// Coalesced reload: resource events arrive for every session on the server.
  func scheduleResources() {
    guard resourcesTask == nil else { return }
    resourcesTask = Task {
      try? await Task.sleep(for: .milliseconds(300))
      resourcesTask = nil
      guard !Task.isCancelled, let all = try? await client.resources() else { return }
      let family = Set([id] + children.map(\.id))
      let next = all.filter { resource in
        guard let owner = resource.owner else { return false }
        return owner.rootSessionID == id || family.contains(owner.sessionID)
      }
      if next != resources { resources = next }
    }
  }
  #if DEBUG
  static let fixturePage = 30
  /// Server-free fixtures (dictation) choose among these in the composer footer's agent sheet.
  func useFixtureAgents(_ value: [AgentInfo]) { agents = value }
  /// Token-sized growth of the newest response at the event batch cadence, while the Session executes.
  private func streamScrollFixture(every interval: Int) async {
    guard let target = messages.last(where: { $0.type == "assistant" && !$0.responseText.isEmpty })?.id else { return }
    active = [id]
    var tick = 0
    while !Task.isCancelled {
      do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
      guard let index = messages.firstIndex(where: { $0.id == target }),
        let part = messages[index].content?.lastIndex(where: { $0.type == "text" }) else { return }
      messages[index].time.completed = nil
      messages[index].content?[part].text?.append(tick % 20 == 0 ? "\n\nParágrafo sintético \(tick)." : " token\(tick)")
      revision += 1
      tick += 1
    }
  }
  private func olderScrollFixture(admitting admit: () async -> Void) async {
    guard !paging, hasOlder else { return }
    paging = true
    defer { paging = false }
    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
    await admit()
    messages = fixtureHistory.suffix(Self.fixturePage) + messages
    fixtureHistory.removeLast(min(Self.fixturePage, fixtureHistory.count))
    hasOlder = !fixtureHistory.isEmpty
    revision += 1
  }
  /// Merges messages delivered while the app was hidden, as a reconnection's tail read would.
  func receiveFixtureArrivals(_ arrivals: [ConversationMessage]) {
    messages = ConversationProjection.merge(messages, page: arrivals)
    revision += 1
  }
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
      do { try await Task.sleep(for: .milliseconds(scrolling ? 120 : 32)) } catch { return }
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
    // Reads that start after an admission was acknowledged observe it, delivered, or cancelled.
    let settled = acknowledged
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
      if hasTranscript, !messages.isEmpty, !replaceHistory {
        nextMessages = try await tailMeetingHistory(pageValue) ?? nextMessages
      }
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
          || !SessionRevert.visible(nextMessages, boundary: boundary).contains(where: { $0.type == "user" }) {
        let older = try await client.conversation(id, cursor: current)
        nextMessages = ConversationProjection.merge(nextMessages, page: older.data.reversed(), older: true)
        cursor = older.data.isEmpty || older.cursor?.next == current ? nil : older.cursor?.next
        hasOlder = cursor != nil
      }
      let directory = infoValue.location.directory
      let nextActive = Set(runningValue.filter { $0.value.isRunning }.map(\.key))
      // An unchanged snapshot (a return, a reconnection) publishes nothing the transcript could lay out again.
      let messagesChanged = nextMessages != messages
      let changed = !hasTranscript || messagesChanged || nextActive != active
      let wasReady = ready
      active = nextActive
      if messagesChanged { messages = nextMessages }
      reversion.reconcile(infoValue, messages: nextMessages)
      hasTranscript = true
      loading = false
      if changed { revision += 1 }
      error = nil
      #if DEBUG
      ConversationOpeningMetrics.mark("published", id: id)
      #endif
      // First content does not depend on Location boot, catalogs or family.
      // Restoration and sending still wait for the stable runtime projection.
      if (try? await client.directoryAvailable(directory)) == false {
        ready = true
        if !wasReady { revision += 1 }
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
      let observed = Set(queueValue.map(\.id) + messages.map(\.id)).union(settled)
      outbox.removeAll { observed.contains($0.id) }
      acknowledged.subtract(settled)
      if preferencesValue.revision >= (preferences?.revision ?? -1) {
        preferences = preferencesValue
      }
      ready = true
      if !wasReady { revision += 1 }
      error = nil
    } catch {
      if !Task.isCancelled {
        if let notice = ConversationNotice.classify(error, directory: session?.location.directory) {
          if case .missingDirectory = notice, hasTranscript, !ready {
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
  /// A conversation retained while away can be more than a page behind its tail. Reads back until the
  /// tail meets the loaded history and merges both; past five pages it starts again from the tail, as a
  /// fresh opening would, rather than leaving a silent gap. Nil when the first page already overlaps.
  private func tailMeetingHistory(_ tail: ConversationPage) async throws -> [ConversationMessage]? {
    let known = Set(messages.map(\.id))
    guard !tail.data.contains(where: { known.contains($0.id) }) else { return nil }
    var page = tail
    var gathered = Array(tail.data.reversed())
    for _ in 0..<5 {
      guard let next = page.cursor?.next, !page.data.isEmpty else { break }
      page = try await client.conversation(id, cursor: next)
      gathered = ConversationProjection.merge(gathered, page: page.data.reversed(), older: true)
      if page.data.contains(where: { known.contains($0.id) }) {
        return ConversationProjection.merge(messages, page: gathered)
      }
    }
    cursor = page.cursor?.next
    hasOlder = !page.data.isEmpty && cursor != nil
    return gathered
  }
  /// Publishes the next older page once `admit` returns, so a reader can hold it until scrolling settles.
  func older(admitting admit: () async -> Void = {}) async {
    #if DEBUG
    if ScrollFixtures.mode != nil { return await olderScrollFixture(admitting: admit) }
    #endif
    guard !paging, hasOlder, let cursor else { return }
    paging = true
    defer { paging = false }
    do {
      let page = try await client.conversation(id, cursor: cursor)
      try Task.checkCancellation()
      await admit()
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
