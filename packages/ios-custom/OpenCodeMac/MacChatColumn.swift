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
      ToolbarItem(placement: .navigation) {
        SessionHeaderTitle(
          row: row, title: transcript?.session?.displayTitle ?? row?.session.displayTitle ?? "OpenCode",
          directory: row.flatMap { store.directoryLabel($0.session) },
          running: row?.state == .running || shownID.map(store.active.contains) == true,
          usage: transcript?.usage)
        .padding(.horizontal, 4)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          if let row {
            Button("Renomear…", systemImage: "pencil") {
              renameText = row.session.title ?? ""
              renaming = true
            }
            Button(row.pinned ? "Desafixar" : "Fixar", systemImage: row.pinned ? "pin.slash" : "pin") {
              Task { await store.pin(row) }
            }
            Button(row.muted ? "Reativar" : "Silenciar", systemImage: row.muted ? "bell" : "bell.slash") {
              Task { await store.mute(row) }
            }
            Divider()
            Button("Excluir sessão…", systemImage: "trash", role: .destructive) { deleteCandidate = row.session }
          }
          Divider()
          Button(runtime.contextVisible ? "Ocultar contexto" : "Mostrar contexto", systemImage: "sidebar.right") {
            runtime.contextVisible.toggle()
          }
        } label: {
          Label("Mais", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Ações da sessão")
        Button {
          NotificationCenter.default.post(name: .macNewSession, object: nil)
        } label: {
          Label("Nova sessão", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.color(.primary))
        .help("Nova sessão")
      }
    }
    .alert("Renomear sessão", isPresented: $renaming) {
      TextField("Título", text: $renameText)
      Button("Cancelar", role: .cancel) {}
      Button("Salvar") { if let row { Task { await store.rename(row, title: renameText) } } }
    }
    .sessionDeleteConfirmation($deleteCandidate, store: store)
  }
}

extension Notification.Name {
  /// The chat toolbar's `+` opens the Nova sessão sheet owned by the Sessões column.
  static let macNewSession = Notification.Name("OpenCodeMacNewSession")
}

/// One conversation's latest page (`custom.transcript/list`), refreshed by the shared event stream.
@MainActor @Observable final class MacTranscriptStore {
  let id: String
  let sessions: SessionStore
  private(set) var session: Session?
  private(set) var messages: [ConversationMessage] = []
  private(set) var models: [ModelInfo] = []
  private(set) var loaded = false
  private(set) var error: String?
  private(set) var sending = false
  var draft = ""
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
  var running: Bool { sessions.active.contains(id) }

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
      let (value, messages) = try await (session, page)
      self.session = value
      self.messages = messages.data.reversed()
      if models.isEmpty { models = (try? await sessions.client.models(directory: value.location.directory)) ?? [] }
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

  /// The iPhone's admission path (`PromptSubmission`) with the session's own agent and model.
  func send() async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !sending, let session, let model = session.model else { return }
    sending = true
    defer { sending = false }
    let agent = session.agent ?? "build"
    let delivery = PromptDelivery.choose(
      busy: running, preference: sessions.preferences?.data.settings.followUpBehavior ?? .steer)
    do {
      try await PromptSubmission(
        request: PromptRequest(text: text, delivery: delivery, agent: agent, model: model),
        sessionID: id, agent: agent, model: model, keepsAgent: true
      ).send(using: sessions.client)
      draft = ""
      await load()
    } catch {
      sessions.toast.show("Não foi possível enviar. \(error.localizedDescription)", kind: .error)
    }
  }
}
