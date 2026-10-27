import Observation
import OpenCodeKit
import SwiftUI

/// The middle column for this first Mac version: a read-only transcript (user bubbles and the assistant's
/// text) and a plain composer. The full iPhone conversation is the next step.
struct MacChatColumn: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: SessionStore
  @Bindable var runtime: MacRuntime
  let context: ContextColumnStore?
  @State private var transcript: MacTranscriptStore?
  @State private var renaming = false
  @State private var renameText = ""
  @State private var deleteCandidate: Session?

  private var shownID: String? { runtime.selection.childID ?? runtime.selection.sessionID }
  private var row: SessionRow? { store.rows.first { $0.id == runtime.selection.sessionID } }

  var body: some View {
    Group {
      if let transcript, shownID != nil {
        MacTranscriptView(store: transcript, runtime: runtime, parentTitle: runtime.selection.childID == nil
          ? nil : row?.session.displayTitle)
      } else {
        ContentUnavailableView("Nenhuma sessão selecionada", systemImage: "bubble.left.and.bubble.right",
          description: Text("Escolha uma sessão na coluna Sessões."))
          .foregroundStyle(theme.color(.textSecondary))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.color(.background))
    .task(id: shownID) {
      guard let id = shownID else {
        transcript = nil
        return
      }
      let next = MacTranscriptStore(id: id, sessions: store)
      transcript = next
      await next.run()
    }
    .toolbar {
      MacPlainToolbarItem(placement: .navigation) {
        MacChatTitle(
          store: store, runtime: runtime,
          title: transcript?.session?.displayTitle ?? row?.session.displayTitle ?? "OpenCode",
          usage: transcript?.usage,
          running: row?.state == .running || shownID.map(store.active.contains) == true)
        .padding(.leading, 6)
      }
      MacToolbarFlexibleSpace()
      MacPlainToolbarItem { MacSessionActions(store: store, runtime: runtime) }
    }
    .onChange(of: runtime.renameRequest?.id) { _, id in
      guard id != nil, let request = runtime.renameRequest else { return }
      renameText = request.session.title ?? ""
      renaming = true
    }
    .onChange(of: runtime.deleteRequest?.id) { _, id in
      guard id != nil else { return }
      deleteCandidate = runtime.deleteRequest
      runtime.deleteRequest = nil
    }
    .alert("Renomear sessão", isPresented: $renaming) {
      TextField("Título", text: $renameText)
      Button("Cancelar", role: .cancel) { runtime.renameRequest = nil }
      Button("Salvar") {
        if let row = runtime.renameRequest { Task { await store.rename(row, title: renameText) } }
        runtime.renameRequest = nil
      }
    }
    .sessionDeleteConfirmation($deleteCandidate, store: store)
  }
}

extension Notification.Name {
  /// The chat toolbar's `+` opens the Nova sessão sheet owned by the Sessões column.
  static let macNewSession = Notification.Name("OpenCodeMacNewSession")
}

/// One conversation's latest page (`custom.transcript/list`), its queue and the composer's choices, refreshed by
/// the shared event stream. The views are the iPhone's shared chat pieces (`OpenCode/ConversationColumn/`).
@MainActor @Observable final class MacTranscriptStore {
  let id: String
  let sessions: SessionStore
  private(set) var session: Session?
  private(set) var messages: [ConversationMessage] = []
  /// Display groups (text, activity cards, dividers) of the visible messages, like the iPhone transcript.
  private(set) var activity = ConversationActivity.empty
  /// The page reaches the start of the conversation, so its first step dates the running execution.
  private(set) var complete = false
  private(set) var inbox: [InboxItem] = []
  private(set) var models: [ModelInfo] = []
  private(set) var agents: [AgentInfo] = []
  private(set) var mcp: [MCPServer] = []
  private(set) var loaded = false
  private(set) var error: String?
  private(set) var sending = false
  private(set) var acting: Set<String> = []
  var draft = ""
  /// The composer's model and agent for the next prompt; nil keeps the session's own.
  var model: ModelReference?
  var agent: String?
  /// Activity cards and tool details opened by Alexandre; everything starts closed.
  var expanded: [String: Bool] = [:]
  @ObservationIgnored private var scheduled: Task<Void, Never>?

  init(id: String, sessions: SessionStore) {
    self.id = id
    self.sessions = sessions
  }

  var usage: ContextUsage? {
    if let context = session?.context {
      return ContextUsage(tokens: context.tokens, limit: ContextUsage.limit(context.model, models: models))
    }
    guard let step = ConversationProjection.latestMeasurement(messages) else { return nil }
    return ContextUsage(tokens: step.tokens, limit: ContextUsage.limit(step.model, models: models))
  }
  /// The whole session's cache hit, like the iPhone's usage line.
  var cacheHit: Double? { ContextUsage.cacheHit(session?.tokens ?? session?.context?.tokens) }
  var running: Bool { sessions.active.contains(id) }
  var queue: [InboxItem] { inbox.filter(\.queuedUser) }
  var marks: TranscriptMarks { TranscriptMarks(messages, working: running) }
  var selectedModel: ModelReference? { model ?? session?.model }
  var selectedAgent: String { agent ?? session?.agent ?? "build" }
  var primaryAgents: [AgentInfo] { agents.filter { $0.mode != "subagent" && $0.hidden != true } }

  /// `Opus 5.5 · xhigh`, like the iPhone composer's capsule.
  func modelLabel(_ reference: ModelReference?) -> String {
    [
      models.first { $0.id == reference?.id && $0.providerID == reference?.providerID }?.name ?? reference?.id,
      reference?.variant == "default" ? nil : reference?.variant,
    ].compactMap { $0 }.joined(separator: " · ")
  }

  func run() async {
    await load()
    for await frame in sessions.hub.events() {
      if Task.isCancelled { break }
      switch frame.event {
      case .connected: schedule()
      case .disconnected: break
      case .update(let event):
        guard event.data.owner == id else { continue }
        schedule(delay: event.type.hasSuffix(".delta") ? 600 : 250)
      }
    }
    scheduled?.cancel()
  }

  func load() async {
    do {
      async let session = sessions.client.session(id)
      async let page = sessions.client.conversation(id)
      async let queued = try? sessions.client.inbox(id)
      let (value, current) = try await (session, page)
      let directory = value.location.directory
      self.session = value
      let ordered = Array(current.data.reversed())
      messages = SessionRevert.visible(ordered, boundary: value.revert?.messageID)
      complete = current.cursor?.next == nil
      activity = ConversationActivity.project(messages, previous: activity, executing: running)
      #if DEBUG
      // Captures can show the first activity card open (`-OpenCodeMacOpenActivity`), like the approved mock.
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacOpenActivity"), expanded.isEmpty,
        let first = activity.messages.flatMap(\.rows).first(where: { $0.kind == .group }) {
        expanded[first.id] = true
      }
      #endif
      inbox = await queued ?? inbox
      if models.isEmpty { models = (try? await sessions.client.models(directory: directory)) ?? [] }
      if agents.isEmpty { agents = (try? await sessions.client.agents(directory: directory)) ?? [] }
      if mcp.isEmpty { mcp = (try? await sessions.client.mcpServers(directory: directory)) ?? [] }
      error = nil
    } catch {
      if !Task.isCancelled { self.error = "Não foi possível carregar a conversa. \(error.localizedDescription)" }
    }
    loaded = true
  }

  private func schedule(delay: Int = 250) {
    guard scheduled == nil else { return }
    scheduled = Task {
      try? await Task.sleep(for: .milliseconds(delay))
      scheduled = nil
      guard !Task.isCancelled else { return }
      await load()
    }
  }

  /// The iPhone's admission path (`PromptSubmission`) with the composer's agent and model; a staged
  /// reversion is committed first, like the iPhone.
  func send() async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !sending, let session, let model = selectedModel else { return }
    sending = true
    defer { sending = false }
    let agent = selectedAgent
    let delivery = PromptDelivery.choose(
      busy: running, preference: sessions.preferences?.data.settings.followUpBehavior ?? .steer)
    do {
      try await PromptSubmission(
        request: PromptRequest(text: text, delivery: delivery, agent: agent, model: model),
        sessionID: id, agent: agent, model: model, keepsAgent: agent == session.agent,
        commitsRevert: session.revert != nil
      ).send(using: sessions.client)
      draft = ""
      await load()
    } catch {
      sessions.toast.show("Não foi possível enviar. \(error.localizedDescription)", kind: .error)
    }
  }

  func stop() async {
    await act("stop", success: "Execução interrompida") { try await self.sessions.client.interrupt(self.id, resume: true) }
  }
  func promote(_ item: InboxItem) async {
    await act(item.id, success: "Mensagem marcada para enviar agora") {
      try await self.sessions.client.promoteInbox(item.id, sessionID: item.sessionID)
    }
  }
  func cancel(_ item: InboxItem) async {
    await act(item.id, success: "Mensagem removida da fila") {
      try await self.sessions.client.cancelInbox(item.id, sessionID: item.sessionID)
    }
  }
  func edit(_ item: InboxItem) async {
    draft = item.payload.displayText
    await cancel(item)
  }
  func toggle(_ server: MCPServer) async {
    guard let directory = session?.location.directory else { return }
    let enabled = server.status.status != .connected
    await act("mcp:" + server.name, success: enabled ? "\(server.name) ativado" : "\(server.name) desativado") {
      try await self.sessions.client.toggleMCP(server.name, enabled: enabled, directory: directory)
      self.mcp = (try? await self.sessions.client.mcpServers(directory: directory)) ?? self.mcp
    }
  }

  /// Desfazer: hides this prompt and everything after it (subagents included) and puts its text back in the
  /// composer; `target: nil` restores them (Refazer).
  func revert(to target: ConversationMessage?) async {
    guard let session, acting.insert("revert").inserted else { return }
    defer { acting.remove("revert") }
    let result = await SessionRevert.perform(
      sessionID: id, target: target, directory: session.location.directory, active: sessions.active,
      pending: inbox, using: sessions.client)
    if result.succeeded, let target { draft = target.displayText }
    if !result.failures.isEmpty {
      sessions.toast.show(result.failures.joined(separator: "\n"), kind: .error)
    }
    await load()
  }

  private func act(_ key: String, success: String, _ action: @escaping () async throws -> Void) async {
    guard acting.insert(key).inserted else { return }
    defer { acting.remove(key) }
    do {
      try await action()
      sessions.toast.show(success)
      await load()
    } catch {
      sessions.toast.show("Não foi possível concluir a ação. \(error.localizedDescription)", kind: .error)
    }
  }
}
