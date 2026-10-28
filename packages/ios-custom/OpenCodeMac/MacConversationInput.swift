import Observation
import OpenCodeKit
import Foundation

/// Window-local composer/audio, backed by the shared conversation and Session-scoped quote RPCs.
@MainActor @Observable final class MacConversationInput {
  let draft: ConversationDraft
  let readAloud = ConversationReadAloud()
  let quotes: QuoteSync
  private let conversation: ConversationStore
  private let sessions: SessionStore
  private var loaded = false

  init(conversation: ConversationStore, sessions: SessionStore, draft: ConversationDraft) {
    self.conversation = conversation
    self.sessions = sessions
    self.draft = draft
    quotes = QuoteSync(sessionID: conversation.id, client: sessions.client, modes: sessions.quoteModes,
      dismissals: sessions.quoteDismissals)
    quotes.draft = draft
    quotes.failed = { [weak conversation] in conversation?.toast.show($0, kind: .error) }
    draft.quoteSync = quotes
  }

  func run() async {
    if !loaded {
      await seedLegacyDraft()
      await draft.load()
      loaded = true
    }
    await sync()
    for await frame in sessions.hub.events() {
      guard !Task.isCancelled else { return }
      switch frame.event {
      case .connected: await sync()
      case .update(let event):
        if event.type == "rpc.custom.quotes.updated", event.data.sessionID == conversation.id,
          let revision = event.data.revision { quotes.updated(revision: revision) }
      default: break
      }
    }
  }

  func sync() async {
    guard let directory = conversation.session?.location.directory else { return }
    quotes.directory = directory
    await quotes.start()
  }

  /// A first window keeps the draft saved before window-local composers existed. Copies preserve the original.
  private func seedLegacyDraft() async {
    do {
      guard try await draft.persistence.load().0 == nil else { return }
      let source = sessions.drafts.draft(conversation.id).persistence
      guard let saved = try await source.load().0 else { return }
      for attachment in saved.attachments where attachment.remotePath == nil {
        try await draft.persistence.store(source.bytes(attachment), attachment: attachment)
      }
      if saved.dictationPending == true {
        try FileManager.default.createDirectory(at: draft.persistence.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.directory.appending(path: "dictation.caf"),
          to: draft.persistence.directory.appending(path: "dictation.caf"))
      }
      try await draft.persistence.save(saved)
    } catch {
      draft.persistenceError = "Não foi possível recuperar o rascunho anterior nesta janela. O original foi preservado."
    }
  }
}
