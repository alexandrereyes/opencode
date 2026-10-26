import Foundation
import Observation
import OpenCodeKit

/// Whether this server stores quotes (`custom.quotes`), probed on open, reconnect and foreground.
@MainActor final class QuoteModes {
  /// `nil` until a probe decides; network and server errors never change it.
  private(set) var mode: QuoteServer.Mode?
  /// Sessions whose migration the server refused (`limit_exceeded`, `session_not_found`): they stay local.
  var local: Set<String> = []
  private var probing: Task<QuoteServer.Mode?, Never>?
  func probe(_ client: OpenCodeClient, directory: String) async -> QuoteServer.Mode? {
    if let probing { return await probing.value }
    let current = mode
    let task = Task<QuoteServer.Mode?, Never> {
      do {
        try await client.quotesInfo(directory: directory)
        return .server
      } catch { return QuoteServer.mode(after: error) ?? current }
    }
    probing = task
    let value = await task.value
    probing = nil
    mode = value
    return value
  }
}

/// The pending quotes of one Session on the server (`packages/plugin-app-custom/docs/quotes.md`).
/// In local mode it does nothing and the draft keeps its own quotes, exactly as before.
@MainActor @Observable final class QuoteSync {
  /// Sent quote IDs whose marks are hidden, from the server; `nil` in local mode.
  private(set) var dismissed: Set<String>?
  @ObservationIgnored private(set) var server = false
  @ObservationIgnored weak var draft: ConversationDraft?
  @ObservationIgnored var directory: String?
  @ObservationIgnored var failed: ((String) -> Void)?
  @ObservationIgnored let sessionID: String
  @ObservationIgnored private let client: OpenCodeClient
  @ObservationIgnored private let modes: QuoteModes
  @ObservationIgnored private let dismissals: ChatQuoteDismissals?
  /// Revision of the state shown, and the highest revision this device wrote: an older listing never wins.
  @ObservationIgnored private var applied: Double = -1
  @ObservationIgnored private var written: Double = 0
  @ObservationIgnored private var known: [String] = []
  /// Sent quotes whose `clear` failed: hidden locally and cleared again on the next sync.
  @ObservationIgnored private var unsent: Set<String> = []
  @ObservationIgnored private var writing = 0
  @ObservationIgnored private var listing: Task<Void, Never>?
  @ObservationIgnored private var starting: Task<Void, Never>?
  @ObservationIgnored private var stale = false
  @ObservationIgnored private var deferred = false

  init(sessionID: String, client: OpenCodeClient, modes: QuoteModes, dismissals: ChatQuoteDismissals?) {
    self.sessionID = sessionID
    self.client = client
    self.modes = modes
    self.dismissals = dismissals
  }

  /// Probe, migrate local drafts once, then list. Runs on open, every reconnect and foreground.
  func start() async {
    if let starting { return await starting.value }
    let task = Task { await begin() }
    starting = task
    await task.value
    starting = nil
  }
  private func begin() async {
    guard let directory, let draft else { return }
    await draft.load()
    guard let mode = await modes.probe(client, directory: directory) else {
      if server { await reload() }
      return
    }
    guard mode == .server, !modes.local.contains(sessionID) else {
      if server { leave() }
      return
    }
    if !server, !(await migrate(draft, directory: directory)) { return }
    server = true
    if !unsent.isEmpty {
      let ids = Array(unsent)
      if (try? await client.clearQuotes(ids, sent: true, sessionID: sessionID, directory: directory)) != nil {
        unsent.subtract(ids)
      }
    }
    await reload()
  }
  /// Local quotes and hidden marks of this Session move to the server; false keeps the draft local.
  private func migrate(_ draft: ConversationDraft, directory: String) async -> Bool {
    let quotes = draft.quotes
    let marks = dismissals?.values(sessionID) ?? []
    guard !quotes.isEmpty || !marks.isEmpty else { return true }
    let persistence = draft.persistence
    let outcome = await QuoteMigration.run(
      quotes: quotes, attachments: draft.attachments, dismissed: Array(marks), sessionID: sessionID,
      directory: directory, client: client, bytes: { try await persistence.bytes($0) })
    switch outcome {
    case .migrated(let state):
      // Only now is the local copy deleted; a crash before this repeats an `import` the server skips.
      draft.applyServerQuotes([], attachments: [])
      await draft.persist()
      try? await persistence.cleanAttachments(retaining: draft.attachments)
      try? dismissals?.remove([sessionID])
      server = true
      apply(state)
      return true
    case .stayLocal:
      modes.local.insert(sessionID)
      return false
    case .retryLater: return false
    }
  }
  private func leave() {
    server = false
    dismissed = nil
    applied = -1
    draft?.leaveServerQuotes()
  }

  /// `rpc.custom.quotes.updated` for this Session.
  func updated(revision: Double) {
    guard server, revision > applied else { return }
    Task { await reload() }
  }
  /// Lists and applies; overlapping calls coalesce into one more listing.
  func reload() async {
    guard server else { return }
    if let listing {
      stale = true
      return await listing.value
    }
    let task = Task {
      repeat {
        stale = false
        guard let directory else { return }
        if let state = try? await client.quotes(sessionID, directory: directory) { apply(state) }
      } while stale
    }
    listing = task
    await task.value
    listing = nil
  }
  private func apply(_ state: QuoteServer.State) {
    guard let draft, state.revision >= applied else { return }
    // Local writes and an optimistic send own the draft until they finish; a newer listing follows.
    // An edited queued prompt shows its quotes as a local preview, as the web does.
    guard writing == 0, !draft.sending, draft.editing == nil, state.revision >= written else {
      deferred = true
      return
    }
    deferred = false
    applied = state.revision
    if dismissed != Set(state.dismissed) { dismissed = Set(state.dismissed) }
    let quotes = state.quotes.filter { !unsent.contains($0.id) }.map(QuoteServer.draft)
    known = quotes.map(\.quote.id)
    draft.applyServerQuotes(quotes.map(\.quote), attachments: quotes.flatMap(\.attachments))
  }
  private func wrote(_ revision: Double) {
    written = max(written, revision)
  }
  private func write(_ operation: () async throws -> Void) async throws {
    writing += 1
    defer {
      writing -= 1
      if writing == 0, deferred { Task { await reload() } }
    }
    try await operation()
  }

  /// After Concluir: uploads new attachments, then saves; an empty comment without attachments removes it.
  func save(_ id: String) async {
    guard server, let directory, let draft, draft.editing == nil,
      let quote = draft.quotes.first(where: { $0.id == id }) else { return }
    if quote.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quote.attachmentParts.isEmpty,
      !draft.attachments.contains(where: { $0.quoteID == id }) {
      draft.dropQuote(id)
      return await remove(id)
    }
    do {
      try await write {
        for attempt in 0..<2 {
          try await upload(id, all: attempt > 0, directory: directory)
          guard let current = draft.quotes.first(where: { $0.id == id }) else { return }
          do {
            let saved = try await client.saveQuote(
              QuoteServer.input(current, attachments: draft.attachments), sessionID: sessionID, directory: directory)
            wrote(saved.revision)
            return
          } catch ClientError.rpc("attachment_missing") where attempt == 0 { continue }
        }
      }
    } catch ClientError.rpc("already_sent") {
      // Another device sent this quote meanwhile; saving it again would send it twice.
      draft.dropQuote(id)
    } catch {
      failed?("Não foi possível salvar a citação no servidor. \(error.localizedDescription)")
    }
  }
  /// Uploads the quote's attachments that are not on the server yet (`all`: after `attachment_missing`).
  private func upload(_ id: String, all: Bool, directory: String) async throws {
    guard let draft else { return }
    var renamed: [String: DraftAttachment] = [:]
    for attachment in draft.attachments where attachment.quoteID == id && attachment.remotePath == nil
      && (all || !QuoteServer.isAttachmentID(attachment.id)) {
      guard let bytes = try? await draft.persistence.bytes(attachment) else { continue }
      let stored = try await client.uploadQuoteAttachment(
        bytes, mime: attachment.mime, filename: attachment.name, sessionID: sessionID, directory: directory)
      guard stored.id != attachment.id else { continue }
      let value = DraftAttachment(id: stored.id, name: attachment.name, mime: stored.mime, size: stored.size,
        quoteID: id)
      try await draft.persistence.store(bytes, attachment: value)
      renamed[attachment.id] = value
    }
    await draft.renameQuoteAttachments(id, renamed)
  }
  func remove(_ id: String) async {
    guard server, let directory, draft?.editing == nil else { return }
    do {
      try await write {
        wrote(try await client.removeQuote(id, sessionID: sessionID, directory: directory))
      }
    } catch { failed?("Não foi possível remover a citação do servidor. \(error.localizedDescription)") }
  }
  /// Only after the server admitted the prompt that carried them.
  func sent(_ ids: [String]) async {
    guard server, !ids.isEmpty, let directory else { return }
    do {
      try await write {
        wrote(try await client.clearQuotes(ids, sent: true, sessionID: sessionID, directory: directory))
      }
    } catch { unsent.formUnion(ids) }
  }
  func dismiss(_ ids: Set<String>) async -> Bool {
    guard server, let directory else { return false }
    dismissed = (dismissed ?? []).union(ids)
    do {
      try await write {
        wrote(try await client.dismissQuotes(Array(ids), sessionID: sessionID, directory: directory))
      }
      return true
    } catch { return false }
  }
  /// Quotes restored into the composer by undo replace the pending ones, as the local draft and the web do.
  /// They become new quotes with new IDs: the server refuses sent ones.
  func restored() async {
    guard server, let directory, let draft else { return }
    draft.reidentifyQuotes()
    let current = Set(draft.quotes.map(\.id))
    let discarded = known.filter { !current.contains($0) }
    if !discarded.isEmpty {
      try? await write {
        wrote(try await client.clearQuotes(discarded, sent: false, sessionID: sessionID, directory: directory))
      }
    }
    for quote in draft.quotes { await save(quote.id) }
  }
  /// Comment attachments keep their bytes on the server; fetch them before an editor or a send reads the file.
  func cache(_ attachments: [DraftAttachment]) async {
    try? await download(attachments)
  }
  func download(_ attachments: [DraftAttachment]) async throws {
    guard server, let directory, let draft else { return }
    for attachment in attachments where attachment.quoteID != nil && attachment.remotePath == nil
      && QuoteServer.isAttachmentID(attachment.id)
      && !FileManager.default.fileExists(atPath: draft.persistence.file(attachment).path) {
      let bytes = try await client.quoteAttachment(attachment.id, sessionID: sessionID, directory: directory)
      try await draft.persistence.store(bytes, attachment: attachment)
    }
  }
}
