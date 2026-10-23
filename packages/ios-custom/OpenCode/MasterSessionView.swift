import OpenCodeKit
import Foundation
import Observation
import SwiftUI

struct MasterSessionView: View {
  @Bindable var sessions: SessionStore
  var body: some View {
    Group {
      if sessions.masterAvailability == .available, let id = sessions.masterID {
        ConversationView(id: id, sessions: sessions, master: true).id(id)
      } else {
        EmptyMasterView(sessions: sessions).id(sessions.masterID)
      }
    }.toastOverlay(sessions.toast)
  }
}

private struct EmptyMasterView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var store: MasterDraftStore
  init(sessions: SessionStore) { _store = State(initialValue: MasterDraftStore(sessions: sessions)) }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button { store.draft.focused = false; dismiss() } label: {
          Image(systemName: "chevron.left").frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: .circle)
        }.accessibilityLabel("Voltar").disabled(store.draft.sending)
        Text("Sessão mestra").font(.system(size: 20, weight: .semibold))
        Spacer()
      }.foregroundStyle(theme.color(.textStrong)).padding(.horizontal, 12).padding(.vertical, 8)
      if store.sessions.masterAvailability == .available {
        Spacer()
        Text("Como posso ajudar com suas sessões?")
          .font(.title2).multilineTextAlignment(.center).foregroundStyle(theme.color(.textStrong))
          .padding(24).accessibilityIdentifier("master-empty")
        Spacer()
        if let error = store.error {
          Button(error + " Tentar novamente") { Task { await store.open() } }
            .font(.caption).foregroundStyle(theme.color(.error)).padding()
        }
        ConversationComposer(store: store.composer, draft: store.draft)
          .padding(.horizontal, 12).padding(.bottom, 6)
      } else {
        ContentUnavailableView {
          Label("Sessão mestra", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
          Text(store.sessions.masterAvailability.label)
        } actions: {
          Button("Verificar novamente") { Task { await store.sessions.loadMaster(); await store.open() } }
        }.accessibilityIdentifier("master-unavailable")
      }
    }.background(theme.color(.background)).tint(theme.color(.primary))
      .toolbar(.hidden, for: .navigationBar, .tabBar)
      .toastOverlay(store.composer.toast).environment(store.composer.toast)
      .task(id: store.sessions.masterAvailability == .available) { await store.open() }
      .onDisappear { store.draft.focused = false }
  }
}

@MainActor @Observable private final class MasterDraftStore {
  let sessions: SessionStore
  let composer: ConversationStore
  let draft: ConversationDraft
  var error: String?
  private var allocation: ChatAllocation?
  private let id = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  init(sessions: SessionStore) {
    self.sessions = sessions
    // A fresh local composer; no server session or managed chat is allocated until Send.
    draft = ConversationDraft(server: sessions.client.configuration.url.absoluteString,
      id: "master-draft-" + UUID().uuidString)
    composer = ConversationStore(id: "master-draft", client: sessions.client,
      hub: sessions.hub, catalog: sessions.catalog)
    composer.masterMode = true
    composer.newSessionSubmit = { [weak self] draft in await self?.send(draft) }
  }
  func open() async {
    guard sessions.masterAvailability == .available else { return }
    do {
      let directory = try await sessions.client.chatRoot()
      try await composer.loadNewSession(directory: directory, projectID: "global", recent: [])
      let info = try await sessions.client.masterInfo()
      let fallback = info.model == nil ? try await sessions.client.defaultModel(directory: directory) : nil
      draft.agent = info.agent
      draft.model = info.model ?? fallback.map { ModelReference(id: $0.id, providerID: $0.providerID) }
      draft.focused = true
      error = nil
    } catch { self.error = "Não foi possível preparar a Sessão mestra." }
  }
  private func send(_ draft: ConversationDraft) async {
    guard !draft.sending, composer.ready, let model = composer.selectedModel(draft),
      !draft.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    else { return }
    draft.sending = true
    defer { draft.sending = false }
    do {
      let document = try await composer.newSessionDocument(draft.document)
      let dispatch = ComposerDispatch.resolve(document)
      if case .local = dispatch {
        composer.toast.show("Este comando precisa de uma sessão existente.", kind: .error)
        return
      }
      if allocation == nil { allocation = try await sessions.client.allocateChat() }
      guard let allocation else { return }
      var delivered: [DeliveredAttachment] = []
      let input = composer.models.first { $0.id == model.id && $0.providerID == model.providerID }?.capabilities?.input ?? []
      for item in draft.attachments {
        if let path = item.remotePath { delivered.append(.init(attachment: item, path: path, inline: nil)); continue }
        delivered.append(try await sessions.client.deliver(item, bytes: draft.persistence.bytes(item),
          directory: allocation.directory, input: input))
      }
      try await sessions.client.claimChat(allocation, sessionID: id)
      try await sessions.client.createSession(id: id, agent: "mestra", model: model, directory: allocation.directory)
      try await sessions.client.claimChat(allocation, sessionID: id, confirm: true)
      let preferences = try await sessions.client.mutate(.masterSet(id))
      do {
        let request = PromptRequest(document: document, delivery: .steer,
          agent: "mestra", model: model, attachments: delivered, quotes: draft.quotes)
        if case .command(let name, _) = dispatch {
          try await sessions.client.command(name, request: request, sessionID: id)
        } else {
          try await sessions.client.prompt(request, sessionID: id)
        }
      } catch {
        let target = sessions.drafts.draft(id)
        await target.load()
        target.text = draft.text
        target.model = model
        target.quotes = draft.quotes
        target.attachments = delivered.map { item in
          DraftAttachment(id: item.attachment.id, name: item.attachment.name, mime: item.attachment.mime,
            size: item.attachment.size, remotePath: item.path, quoteID: item.attachment.quoteID)
        }
        await target.persist()
        sessions.toast.show("A sessão foi criada, mas a mensagem não foi enviada. Seu texto foi mantido.", kind: .error)
      }
      draft.focused = false
      sessions.adoptMaster(preferences)
      Haptics.play(.light)
    } catch {
      composer.toast.show("Não foi possível criar a Sessão mestra. Seu texto foi mantido.", kind: .error)
    }
  }
}
