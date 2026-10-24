import Foundation
import OpenCodeKit

enum VoiceMasterUpdate: Sendable {
  case progress(String), finished(String), failed(String), disconnected
}

@MainActor protocol VoiceMasterServing: AnyObject {
  func ask(_ request: VoiceMasterRequest) async throws
  func stop()
}

@MainActor final class VoiceMaster: VoiceMasterServing {
  private let sessions: SessionStore
  private let update: @MainActor (VoiceMasterUpdate) -> Void
  private var subscription: Task<Void, Never>?
  private var masterID: String?
  private var allocation: ChatAllocation?
  private var allocatedID = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  private var messages: [ConversationMessage] = []
  private var waiting = false
  private var admitted = false
  private var terminalPending = false
  private var promptID: String?
  private var lastSequence = 0
  private var revision = 0

  init(sessions: SessionStore, update: @escaping @MainActor (VoiceMasterUpdate) -> Void) {
    self.sessions = sessions; self.update = update
  }
  func ask(_ request: VoiceMasterRequest) async throws {
    let info = try await sessions.client.masterInfo()
    guard info.version == 1 else { throw ClientError.operation("Atualize o servidor para usar a Sessão mestra.") }
    if masterID == nil {
      // Re-read the pointer: a text composer may have created the master since call start.
      let preferences = try await sessions.client.preferences()
      sessions.adoptMaster(preferences)
      if let id = sessions.masterID {
        let session = try await sessions.client.session(id)
        guard session.time.archived == nil else { throw ClientError.operation("A Sessão mestra foi arquivada. Inicie outra conversa por voz.") }
        masterID = id
      } else {
        if allocation == nil { allocation = try await sessions.client.allocateChat() }
        guard let allocation else { throw ClientError.operation("Não foi possível preparar a Sessão mestra.") }
        let fallback = info.model == nil ? try await sessions.client.defaultModel(directory: allocation.directory) : nil
        guard let model = info.model ?? fallback.map({ ModelReference(id: $0.id, providerID: $0.providerID) }) else {
          throw ClientError.operation("Escolha um modelo para a Sessão mestra.")
        }
        try Task.checkCancellation()
        try await sessions.client.claimChat(allocation, sessionID: allocatedID)
        try await sessions.client.createSession(id: allocatedID, agent: "mestra", model: model, directory: allocation.directory)
        try await sessions.client.claimChat(allocation, sessionID: allocatedID, confirm: true)
        sessions.adoptMaster(try await sessions.client.mutate(.masterSet(allocatedID)))
        masterID = allocatedID
      }
    }
    guard let masterID else { return }
    let session = try await sessions.client.session(masterID)
    guard let model = session.model ?? info.model else { throw ClientError.operation("A Sessão mestra não tem modelo selecionado.") }
    if subscription == nil { subscribe() }
    waiting = true
    admitted = false; terminalPending = false
    revision += 1
    messages = []
    let prompt = PromptRequest(text: request.text, delivery: request.delivery, agent: "mestra", model: model)
    promptID = prompt.id
    try Task.checkCancellation()
    // Durable admission only; execution continues independently and is observed below.
    try await sessions.client.prompt(prompt, sessionID: masterID)
    admitted = true
    update(.progress(request.delivery == .queue ? "Pedido na fila da Sessão mestra." : "Pedido enviado à Sessão mestra."))
    if terminalPending { await reconcile() }
  }
  private func subscribe() {
    let events = sessions.hub.events()
    subscription = Task { [weak self] in
      for await frame in events {
        guard !Task.isCancelled, let self else { break }
        let gap = lastSequence > 0 && frame.sequence != lastSequence + 1
        lastSequence = frame.sequence
        if gap { await reconcile() }
        switch frame.event {
        case .disconnected: if waiting { update(.disconnected) }
        case .connected: if waiting { await reconcile() }
        case .update(let event):
          await receive(event)
        }
      }
    }
  }
  func receive(_ event: ConversationEvent) async {
    guard waiting, event.data.owner == masterID else { return }
    ConversationReducer.apply(event, to: &messages)
    if let call = VoiceMasterProgress.call(event), ["session_read", "session_status", "session_wait"].contains(call.name),
      let id = call.sessionID,
      let title = sessions.entries.first(where: { $0.session.id == id })?.session.displayTitle {
      update(.progress("A mestra está conferindo a sessão “" + String(title.prefix(120)) + "”."))
    } else if let text = VoiceMasterProgress.describe(event) { update(.progress(text)) }
    if event.type == "session.execution.succeeded" {
      terminalPending = true
      if admitted { await reconcile() }
    }
    if event.type == "session.execution.failed" || event.type == "session.execution.interrupted" {
      waiting = false
      update(.failed(event.type.hasSuffix("interrupted") ? "A execução da mestra foi interrompida." : "A Sessão mestra encontrou uma falha. Confira a conversa."))
    }
    if event.type == "form.created" || event.type == "permission.asked" {
      update(.progress("A mestra precisa da sua resposta. Abra a Sessão mestra para conferir."))
    }
  }
  private func reconcile() async {
    guard waiting, admitted, let masterID, let promptID else { return }
    let revision = revision
    do {
      let active = try await sessions.client.active()
      guard self.revision == revision, waiting, active[masterID]?.isRunning != true else { return }
      // An admitted queue item can remain pending while another execution ends.
      guard try await sessions.client.inbox(masterID).isEmpty else { return }
      guard self.revision == revision, waiting else { return }
      var page = try await sessions.client.conversation(masterID)
      var rows = page.data
      // Use the durable prompt ID, not wall clocks from two different devices.
      for _ in 0..<4 where !rows.contains(where: { $0.id == promptID }) {
        guard let cursor = page.cursor?.next else { break }
        page = try await sessions.client.conversation(masterID, cursor: cursor)
        rows.append(contentsOf: page.data)
      }
      guard self.revision == revision, waiting else { return }
      guard let boundary = rows.firstIndex(where: { $0.id == promptID }) else {
        waiting = false
        update(.failed("Não consegui recuperar toda a resposta. Confira a Sessão mestra."))
        return
      }
      messages = Array(rows.prefix(boundary).reversed())
      let text = messages.last(where: { $0.type == "assistant" && !$0.responseText.isEmpty })?.responseText ?? ""
      guard !text.isEmpty else { return }
      waiting = false
      update(.finished(text.count > 5000
        ? "A resposta é longa. Segue o trecho final; confira a resposta completa na conversa. " + String(text.suffix(5000))
        : text))
    } catch { if self.revision == revision, waiting { update(.disconnected) } }
  }
  func stop() {
    subscription?.cancel(); subscription = nil
    waiting = false
    // Ending audio must never interrupt or erase work already admitted to the master.
  }
}

#if DEBUG
@MainActor final class VoiceFakeMaster: VoiceMasterServing {
  let update: @MainActor (VoiceMasterUpdate) -> Void
  private var task: Task<Void, Never>?
  init(update: @escaping @MainActor (VoiceMasterUpdate) -> Void) { self.update = update }
  func ask(_ request: VoiceMasterRequest) async throws {
    task?.cancel()
    update(.progress("A mestra está conferindo uma sessão de demonstração."))
    task = Task {
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      update(.finished("Demonstração concluída. Nenhuma sessão real foi consultada ou alterada."))
    }
  }
  func stop() { task?.cancel(); task = nil }
}
#endif
