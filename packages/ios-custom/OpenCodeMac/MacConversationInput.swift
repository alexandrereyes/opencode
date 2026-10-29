import Observation
import OpenCodeKit
import Foundation

/// Window-local composer/audio, backed by the shared conversation and Session-scoped quote RPCs.
@MainActor @Observable final class MacConversationInput {
  let draft: ConversationDraft
  let readAloud = ConversationReadAloud()
  let quotes: QuoteSync
  /// The title ring's share of the context, read from the transcript that every streamed delta changes.
  @ObservationIgnored let contextFraction: MacSampled<Double?>
  /// When the running execution started, for the tray's elapsed time; also read from the streamed transcript.
  @ObservationIgnored let executionStarted: MacSampled<Double?>
  private let conversation: ConversationStore
  private let sessions: SessionStore
  private var loaded = false

  init(conversation: ConversationStore, sessions: SessionStore, draft: ConversationDraft) {
    self.conversation = conversation
    self.sessions = sessions
    self.draft = draft
    contextFraction = MacSampled { [weak conversation] in conversation?.sessionUsage?.fraction }
    executionStarted = MacSampled { [weak conversation] in
      conversation.flatMap { ConversationProjection.executionStarted($0.messages, complete: !$0.hasOlder) }
    }
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

/// A value read from observable state, republished at most every `interval` and only when it changes: secondary
/// information streamed deltas would otherwise update, and lay the window out, many times a second. The last
/// change is always published, one interval later at most.
@MainActor @Observable final class MacSampled<Value: Equatable> {
  private(set) var value: Value
  @ObservationIgnored private let read: () -> Value
  @ObservationIgnored private let interval: Duration
  @ObservationIgnored private var scheduled = false

  init(every interval: Duration = .milliseconds(200), _ read: @escaping () -> Value) {
    self.read = read
    self.interval = interval
    value = read()
    observe()
  }

  private func observe() {
    let next = withObservationTracking(read) { [weak self] in
      Task { @MainActor in self?.changed() }
    }
    if next != value { value = next }
  }

  private func changed() {
    guard !scheduled else { return }
    scheduled = true
    Task { @MainActor [weak self, interval] in
      try? await Task.sleep(for: interval)
      guard let self else { return }
      scheduled = false
      observe()
    }
  }
}
