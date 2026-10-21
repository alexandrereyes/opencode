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
        let token = try? JSONDecoder().decode(ComposerToken.self, from: data),
        (attributed.string as NSString).substring(with: range) == token.text
      else { return }
      tokens.append(.init(start: range.location, end: NSMaxRange(range), token: token))
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
  var text = NSAttributedString() { didSet { changed() } }
  var model: ModelReference? { didSet { changed() } }
  var agent: String? { didSet { changed() } }
  var attachments: [DraftAttachment] = [] { didSet { changed() } }
  var quotes: [ChatQuote] = [] { didSet { changed() } }
  var commenting: ChatQuote?
  var selection = NSRange(location: 0, length: 0)
  var focused = false
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

  init(server: String, id: String) { persistence = DraftPersistence(server: server, sessionID: id) }
  var document: ComposerDocument { ComposerDocument(attributed: text) }
  var snapshot: DraftSnapshot {
    .init(
      document: document, attachments: attachments, model: model, agent: agent,
      cursor: selection.location, replacing: replacing, quotes: quotes)
  }
  var trigger: ComposerTrigger? {
    guard focused, selection.length == 0 else { return nil }
    let trigger = ComposerTrigger.detect(in: document, cursor: selection.location)
    return trigger == dismissedTrigger ? nil : trigger
  }
  func load() async {
    guard !restored else { return }
    restored = true
    restoring = true
    defer { restoring = false }
    do {
      let (value, dropped) = try await persistence.load()
      if let value {
        text = value.document.attributed
        attachments = value.attachments
        quotes = value.quotes
        model = value.model
        agent = value.agent
        replacing = value.replacing
        selection = NSRange(location: min(value.cursor, text.length), length: 0)
      }
      if dropped {
        persistenceError =
          "Alguns anexos não foram restaurados (limite de 25 MiB ou arquivo indisponível)."
      }
      try await persistence.cleanAttachments(retaining: attachments)
    } catch { persistenceError = "Não foi possível restaurar o rascunho." }
  }
  func persist() async {
    saving?.cancel()
    do { try await persistence.save(snapshot) } catch {
      persistenceError = "Não foi possível salvar o rascunho."
    }
  }
  private func changed() {
    guard restored, !restoring else { return }
    saving?.cancel()
    saving = Task {
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      await persist()
    }
  }
  func insert(_ token: ComposerToken, replacing range: NSRange) {
    let value = NSMutableAttributedString(attributedString: text)
    value.replaceCharacters(
      in: range,
      with: ComposerDocument(
        text: token.text,
        tokens: [.init(start: 0, end: token.text.utf16.count, token: token)]
      ).attributed)
    value.insert(NSAttributedString(string: " "), at: range.location + token.text.utf16.count)
    selection = NSRange(location: range.location + token.text.utf16.count + 1, length: 0)
    text = value
    dismissedTrigger = nil
    focused = true
  }
  func insertTrigger(_ marker: String) {
    let value = NSMutableAttributedString(attributedString: text)
    let position = marker == "/" ? 0 : min(selection.location, value.length)
    let separator =
      position > 0 && !(value.string as NSString).substring(to: position).hasSuffix(" ") ? " " : ""
    value.insert(NSAttributedString(string: separator + marker), at: position)
    selection = NSRange(location: position + separator.utf16.count + 1, length: 0)
    text = value
    focused = true
    dismissedTrigger = nil
  }
  func dismissSuggestions() { dismissedTrigger = trigger }
  func remove(_ attachment: DraftAttachment) {
    attachments.removeAll { $0.id == attachment.id }
    Task {
      await persist()
      try? await persistence.cleanAttachments(retaining: attachments)
    }
  }
  func clear() async {
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
    text = ComposerDocument(restoring: item.payload).attributed
    quotes = ChatQuote.read(item.payload.metadata?["quotes"])
    selection = NSRange(location: text.length, length: 0)
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
  func draft(_ id: String) -> ConversationDraft {
    if let draft = values[id] { return draft }
    let draft = ConversationDraft(server: server, id: id)
    values[id] = draft
    return draft
  }
}
