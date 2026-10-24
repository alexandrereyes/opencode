import Foundation
import Observation
import OpenCodeKit
import UIKit

extension NSAttributedString.Key {
  static let composerToken = NSAttributedString.Key("OpenCodeComposerToken")
}

extension ComposerDocument {
  init(attributed: NSAttributedString) {
    self.init(text: attributed.string)
    attributed.enumerateAttribute(
      .composerToken, in: NSRange(location: 0, length: attributed.length)
    ) { value, range, _ in
      guard let data = value as? Data,
        let token = try? JSONDecoder().decode(ComposerToken.self, from: data)
      else { return }
      let length = token.text.utf16.count
      guard length > 0, range.length % length == 0,
        (attributed.string as NSString).substring(with: range)
          == String(repeating: token.text, count: range.length / length)
      else { return }
      // Foundation merges neighboring equal attributes, including repeated identical tokens.
      for start in stride(from: range.location, to: NSMaxRange(range), by: length) {
        tokens.append(.init(start: start, end: start + length, token: token))
      }
    }
  }
  var attributed: NSAttributedString {
    let value = NSMutableAttributedString(string: text)
    for span in validTokens {
      if let data = try? JSONEncoder().encode(span.token) {
        value.addAttribute(.composerToken, value: data, range: span.range)
      }
    }
    return value
  }
}
extension ComposerTokenKind {
  var role: ThemeRole {
    switch self {
    case .file, .reference: .composerFile
    case .session: .composerSession
    case .agent: .composerAgent
    case .command: .composerCommand
    case .skill: .composerSkill
    case .snippet: .composerSnippet
    }
  }
}

@MainActor @Observable final class ConversationDraft {
  @ObservationIgnored private(set) var editorText = NSAttributedString()
  // Native edits publish contentRevision without echoing storage/selection back into TextKit.
  private(set) var sourceRevision = 0
  private(set) var contentRevision = 0
  var text: NSAttributedString {
    get { document.attributed }
    set {
      editorText = ComposerDocument(attributed: newValue).editorAttributed()
      sourceRevision += 1
      contentRevision += 1
      changed()
    }
  }
  var hasText: Bool {
    _ = contentRevision
    return (editorText.string as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted).location != NSNotFound
  }
  var isEmpty: Bool { _ = contentRevision; return editorText.length == 0 }
  var model: ModelReference? { didSet { changed() } }
  var newSession: NewSessionContext? { didSet { changed() } }
  var agent: String? { didSet { changed() } }
  var attachments: [DraftAttachment] = [] { didSet { changed() } }
  var quotes: [ChatQuote] = [] { didSet { changed() } }
  var revertedContext: RevertedContext? { didSet { changed() } }
  var commenting: ChatQuote?
  // Editor UTF-16 offsets; snapshots convert the cursor to the persisted label offsets.
  var selection = NSRange(location: 0, length: 0)
  var focused = false
  // Presentation is runtime-only, including transfer after a failed new-session send.
  var expanded = false
  var dictationReview = false
  private var dictationPending = false { didSet { changed() } }
  @ObservationIgnored var recordingFactory: ((URL) -> VoiceRecordingComposer)?
  @ObservationIgnored lazy var recording: VoiceRecordingComposer = {
    let file = persistence.directory.appending(path: "dictation.caf")
    let recording = recordingFactory?(file) ?? VoiceRecordingComposer(file: file)
    recording.pendingChanged = { [weak self] pending in
      self?.dictationPending = pending
      if pending { Task { await self?.persist() } }
    }
    recording.receive = { [weak self] text in await self?.insertTranscription(text) }
    return recording
  }()
  func insertTranscription(_ text: String) async {
    guard !deleted else { return }
    // Pending downloads must not overwrite text typed meanwhile or a selected token.
    let location = min(selection.location, editorText.length)
    let prefix = location > 0 && !(editorText.string as NSString).substring(with: NSRange(location: location - 1, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : ""
    let suffix = location < editorText.length && !(editorText.string as NSString).substring(with: NSRange(location: location, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : ""
    replace(NSRange(location: location, length: 0), with: NSAttributedString(string: prefix + text + suffix, attributes: input?.plainAttributes))
    dictationPending = false
    dictationReview = true
    await persist()
  }
  private(set) var sendRevision = 0
  func didSend() {
    sendRevision += 1
    focused = false
    expanded = false
  }
  var focusSuppressed = false
  @ObservationIgnored weak var input: ComposerInputView?
  var editorOwner: UUID?
  var dismissedTrigger: ComposerTrigger?
  var editing: InboxItem?
  var replacing: String? { didSet { changed() } }
  var sending = false
  var importing = false
  var error: String?
  var submission: PromptSubmission?
  var submissionDocument: DraftSnapshot?
  var restored = false
  var persistenceError: String?
  let persistence: DraftPersistence
  @ObservationIgnored private var saving: Task<Void, Never>?
  @ObservationIgnored private var restoring = false
  @ObservationIgnored private var deleted = false

  init(server: String, id: String) { persistence = DraftPersistence(server: server, sessionID: id) }
  var document: ComposerDocument { _ = contentRevision; return ComposerDocument(editor: editorText) }
  var snapshot: DraftSnapshot {
    let document = self.document
    return .init(
      document: document, attachments: attachments, model: model, agent: agent,
      cursor: document.documentOffset(selection.location), replacing: replacing, quotes: quotes, newSession: newSession,
      revertedContext: revertedContext, dictationPending: dictationPending ? true : nil)
  }
  var trigger: ComposerTrigger? {
    guard focused, selection.length == 0, input?.markedTextRange == nil else { return nil }
    _ = contentRevision
    let trigger = ComposerTrigger.detect(in: editorText.string as NSString, cursor: selection.location)
    return trigger == dismissedTrigger ? nil : trigger
  }
  func load() async {
    guard !restored, !deleted else { return }
    restored = true
    restoring = true
    defer { restoring = false }
    do {
      let (value, dropped) = try await persistence.load()
      guard !deleted else { return }
      if let value {
        text = value.document.attributed
        attachments = value.attachments
        quotes = value.quotes
        revertedContext = value.revertedContext
        model = value.model
        newSession = value.newSession
        agent = value.agent
        replacing = value.replacing
        selection = NSRange(location: value.document.editorOffset(value.cursor), length: 0)
        dictationPending = value.dictationPending == true
        if dictationPending { recording.restorePending() }
      }
      if dropped {
        persistenceError =
          "Alguns anexos não foram restaurados (limite de 25 MiB ou arquivo indisponível)."
      }
      try await persistence.cleanAttachments(retaining: attachments)
    } catch { persistenceError = "Não foi possível restaurar o rascunho." }
  }
  func persist() async {
    guard !deleted else { return }
    saving?.cancel()
    do { try await persistence.save(snapshot) } catch {
      persistenceError = "Não foi possível salvar o rascunho."
    }
  }
  /// While an optimistic send owns the cleared composer, disk keeps the unsent draft until the
  /// send succeeds (explicit `clear()`) or fails (restored, then persisted).
  @ObservationIgnored var holdsPersistence = false {
    didSet {
      guard holdsPersistence, !oldValue, restored, !deleted else { return }
      // Replace a pending debounced save with the unsent draft before the composer clears.
      saving?.cancel()
      let snapshot = snapshot
      saving = Task { try? await persistence.save(snapshot) }
    }
  }
  private func changed() {
    guard restored, !restoring, !deleted, !holdsPersistence else { return }
    saving?.cancel()
    saving = Task {
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      await persist()
    }
  }
  func insert(_ token: ComposerToken, replacing range: NSRange) {
    let value = NSMutableAttributedString(attributedString: ComposerDocument(
        text: token.text,
        tokens: [.init(start: 0, end: token.text.utf16.count, token: token)]
      ).editorAttributed(theme: input?.composerTheme ?? .selected))
    value.append(NSAttributedString(string: " ", attributes: input?.plainAttributes))
    replace(range, with: value)
    dismissedTrigger = nil
    focused = true
  }
  func discard() async throws {
    recording.discard()
    revertedContext = nil
    deleted = true
    saving?.cancel()
    await saving?.value
    focused = false
    text = NSAttributedString()
    attachments = []
    quotes = []
    commenting = nil
    editing = nil
    replacing = nil
    selection = NSRange(location: 0, length: 0)
    submission = nil
    submissionDocument = nil
    try await persistence.remove()
  }
  func dismissSuggestions() { dismissedTrigger = trigger }
  func receiveEditor(_ view: ComposerInputView) {
    guard view.representedDraft === self, view.representedRevision == sourceRevision else {
      contentRevision += 1
      return
    }
    editorText = view.textStorage
    selection = view.selectedRange
    contentRevision += 1
    changed()
  }
  func replace(_ range: NSRange, with value: NSAttributedString) {
    // A queued transcription may finish after the old input has left the screen.
    if let input, input.representedDraft === self, input.representedRevision == sourceRevision,
      editorOwner != nil, input.composerOwner == editorOwner {
      input.replaceCharacters(in: range, with: value)
      return
    }
    let result = NSMutableAttributedString(attributedString: editorText)
    result.replaceCharacters(in: range, with: value)
    editorText = result
    selection = NSRange(location: range.location + value.length, length: 0)
    sourceRevision += 1
    contentRevision += 1
    changed()
  }
  func remove(_ attachment: DraftAttachment) {
    attachments.removeAll { $0.id == attachment.id }
    Task {
      await persist()
      try? await persistence.cleanAttachments(retaining: attachments)
    }
  }
  func clear() async {
    recording.discard()
    revertedContext = nil
    text = NSAttributedString()
    attachments = []
    quotes = []
    selection = NSRange(location: 0, length: 0)
    editing = nil
    replacing = nil
    submission = nil
    submissionDocument = nil
    await persist()
    try? await persistence.cleanAttachments(retaining: [])
  }
  func removeQuote(_ quote: ChatQuote) {
    quotes.removeAll { $0.id == quote.id }
    attachments.removeAll { $0.quoteID == quote.id }
    Task {
      await persist()
      try? await persistence.cleanAttachments(retaining: attachments)
    }
  }
  func restore(_ item: InboxItem) {
    revertedContext = nil
    text = ComposerDocument(restoring: item.payload).attributed
    quotes = ChatQuote.read(item.payload.metadata?["quotes"])
    selection = NSRange(location: editorText.length, length: 0)
    attachments = (item.payload.metadata?["attachments"]?.array ?? []).compactMap { value in
      guard let object = value.object, let name = object["name"]?.string,
        let mime = object["mime"]?.string, let path = object["path"]?.string
      else { return nil }
      return DraftAttachment(name: name, mime: mime, size: 0, remotePath: path)
    }
    attachments += quotes.flatMap { quote in
      quote.attachmentParts.compactMap { value -> DraftAttachment? in
        guard let part = value.object, part["type"]?.string == "path",
          let path = part["path"]?.string,
          let id = part["id"]?.string, let name = part["filename"]?.string,
          let mime = part["mime"]?.string
        else { return nil }
        return DraftAttachment(
          id: id, name: name, mime: mime, size: 0, remotePath: path, quoteID: quote.id)
      }
    }
    editing = item
    replacing = item.id
    submission = nil
    error = nil
    agent = item.payload.metadata?["agent"]?.string
    if let value = item.payload.metadata?["model"]?.object,
      let id = value["modelID"]?.string, let provider = value["providerID"]?.string
    {
      model = ModelReference(id: id, providerID: provider, variant: value["variant"]?.string)
    }
    // Materialized inline bytes are not prompt-input objects: turn them back into local attachments.
    let quoted = quotes.flatMap { quote in quote.inlineIDs.map { (quoteID: quote.id, id: $0) } }
    let files = item.payload.files ?? []
    let firstQuote = files.count - quoted.count
    let inline = files.enumerated().filter {
      $0.element.object?["mention"] == nil
        && $0.element.object?["source"]?.object?["type"]?.string == "inline"
    }
    if !inline.isEmpty {
      importing = true
      Task {
        defer { importing = false }
        for (index, file) in inline {
          guard let object = file.object, let encoded = object["data"]?.string,
            let bytes = Data(base64Encoded: encoded), let mime = object["mime"]?.string
          else { continue }
          guard
            attachments.reduce(0, { $0 + $1.size }) + bytes.count <= AttachmentEncoding.draftLimit
          else {
            persistenceError = "Alguns anexos excedem o limite de 25 MiB do rascunho."
            continue
          }
          let quote = firstQuote >= 0 && index >= firstQuote ? quoted[index - firstQuote] : nil
          let attachment = DraftAttachment(
            id: quote?.id ?? UUID().uuidString,
            name: object["name"]?.string ?? "Anexo", mime: mime, size: bytes.count,
            quoteID: quote?.quoteID)
          do {
            try await persistence.store(bytes, attachment: attachment)
            attachments.append(attachment)
          } catch { persistenceError = "Não foi possível restaurar o anexo da fila." }
        }
        await persist()
      }
    }
  }
}

@MainActor final class ConversationDrafts {
  private var values: [String: ConversationDraft] = [:]
  private let server: String
  init(server: String) { self.server = server }
  func flush() async {
    for draft in values.values {
      draft.recording.suspend()
      draft.focused = false
      await draft.persist()
    }
  }
  func draft(_ id: String) -> ConversationDraft {
    if let draft = values[id] { return draft }
    let draft = ConversationDraft(server: server, id: id)
    values[id] = draft
    return draft
  }
  func remove(_ ids: Set<String>) async throws {
    for id in ids {
      // Keep an empty, disabled draft until this runtime ends: disappearing editors
      // can still hold it or ask for it while NavigationStack is animating away.
      try await draft(id).discard()
    }
  }
}
