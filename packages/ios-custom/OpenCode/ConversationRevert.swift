import Foundation
import Observation
import OpenCodeKit
import SwiftUI

struct UserMessageRevertAction {
  let pending: Bool
  let revert: (String) -> Void
}

extension EnvironmentValues {
  @Entry var userMessageRevert: UserMessageRevertAction? = nil
}

@MainActor @Observable final class ConversationRevert {
  private(set) var progress: RevertProgress?
  private(set) var local = false
  private(set) var messageID: String?
  var pending: Bool { progress != nil }
  private let client: OpenCodeClient
  @ObservationIgnored private var operation: Task<Bool, Never>?
  @ObservationIgnored private var generation = UUID()
  init(client: OpenCodeClient) { self.client = client }

  func boundary(_ session: Session?) -> String? { local ? messageID : session?.revert?.messageID }

  func reconcile(_ session: Session, messages: [ConversationMessage]? = nil) {
    guard !pending, local else { return }
    if session.revert?.messageID == messageID { local = false; return }
    if let messageID, let messages, !messages.contains(where: { $0.id == messageID }) { local = false }
  }

  func perform(target: ConversationMessage?, store: ConversationStore, draft: ConversationDraft) async {
    if let operation, local, messageID == target?.id { _ = await operation.value; return }
    guard !draft.sending, !draft.importing, let session = store.session else { return }
    let prompt = target.map { RevertedPrompt($0, directory: session.location.directory) }
    do {
      // Lean history removes tool-result media only; user attachments are already complete.
      try draft.projectReverted(prompt)
    } catch {
      store.toast.show("Não foi possível restaurar a mensagem. \(error.localizedDescription)", kind: .error)
      return
    }
    let previous = operation
    let generation = UUID()
    self.generation = generation
    progress = .planning
    local = true
    messageID = target?.id
    store.updateActivity()
    if let previous = target.flatMap({ SessionRevert.undo(store.messages, boundary: $0.id) })
      ?? (target == nil ? SessionRevert.users(store.messages).last : nil) {
      store.revealMessage(previous.id)
    }
    Haptics.play(.light)
    let operation = Task { @MainActor in
      if let previous, !(await previous.value) { return false }
      do { try await draft.persistReverted(prompt) } catch {
        store.toast.show("Não foi possível salvar os anexos restaurados. \(error.localizedDescription)", kind: .error)
        return false
      }
      let result = await SessionRevert.perform(sessionID: session.id, target: target,
        directory: session.location.directory, active: store.active, pending: store.inbox, using: client,
        progress: { [weak self] value in await self?.report(value) })
      if !result.failures.isEmpty {
        let title = result.succeeded ? "A sessão foi atualizada, mas houve falha nos subagentes." : "Não foi possível atualizar a sessão."
        store.toast.show(title + " " + result.failures.joined(separator: "\n"), kind: .error)
      }
      await store.refresh()
      return result.succeeded
    }
    self.operation = operation
    let succeeded = await operation.value
    guard self.generation == generation else { return }
    self.operation = nil
    progress = nil
    if !succeeded { local = false }
    if let current = store.session { reconcile(current, messages: store.messages) }
    store.updateActivity()
  }

  private func report(_ value: RevertProgress) { progress = value }

  func wait() async -> Bool {
    while let operation {
      let current = generation
      if !(await operation.value) { return false }
      if generation == current { return true }
    }
    return true
  }
}

@MainActor final class ConversationReverts {
  private var values: [String: ConversationRevert] = [:]
  func value(_ id: String, client: OpenCodeClient) -> ConversationRevert {
    if let value = values[id] { return value }
    let value = ConversationRevert(client: client)
    values[id] = value
    return value
  }
}

extension ConversationDraft {
  func projectReverted(_ prompt: RevertedPrompt?) throws {
    guard (prompt?.attachments.reduce(0, { $0 + $1.size }) ?? 0) <= AttachmentEncoding.draftLimit else { throw AttachmentError.tooLarge }
    text = (prompt?.document ?? ComposerDocument()).attributed
    attachments = prompt?.attachments ?? []
    quotes = prompt?.quotes ?? []
    revertedContext = prompt?.context
    editing = nil
    replacing = nil
    commenting = nil
    submission = nil
    submissionDocument = nil
    selection = NSRange(location: editorText.length, length: 0)
    error = nil
  }

  func persistReverted(_ prompt: RevertedPrompt?) async throws {
    for attachment in prompt?.attachments ?? [] {
      if let bytes = prompt?.bytes[attachment.id] { try await persistence.store(bytes, attachment: attachment) }
    }
    await persist()
    try await persistence.cleanAttachments(retaining: attachments)
  }
}

struct ConversationRevertStatus: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let draft: ConversationDraft
  var body: some View {
    if let context = draft.revertedContext {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(context.files.enumerated()), id: \.offset) { index, file in
          HStack {
            Label(file.object?["name"]?.string ?? "Arquivo de contexto", systemImage: "doc.text")
            Spacer()
            Button("Remover arquivo de contexto", systemImage: "xmark") {
              draft.revertedContext?.files.remove(at: index)
            }.labelStyle(.iconOnly)
          }
        }
        ForEach(Array((context.comments?.array ?? []).enumerated()), id: \.offset) { index, comment in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(comment.object?["path"]?.string ?? "Comentário em arquivo")
              Text(comment.object?["comment"]?.string ?? "").lineLimit(2)
            }
            Spacer()
            Button("Remover comentário", systemImage: "xmark") {
              var comments = context.comments?.array ?? []
              comments.remove(at: index)
              draft.revertedContext?.comments = .array(comments)
            }.labelStyle(.iconOnly)
          }
        }
      }.font(.caption).foregroundStyle(theme.color(.textSecondary))
        .padding(.horizontal, 16)
    }
    if let progress = store.reversion.progress {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(progress.label).font(.caption)
        Spacer()
      }.foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityIdentifier("revert-progress")
    } else if let boundary = store.reversion.boundary(store.session),
      store.messages.contains(where: { $0.id == boundary }) {
      HStack {
        Button("Desfazer", systemImage: "arrow.uturn.backward") {
          guard let target = SessionRevert.undo(store.messages, boundary: boundary) else { return }
          Task { await store.reversion.perform(target: target, store: store, draft: draft) }
        }.disabled(SessionRevert.undo(store.messages, boundary: boundary) == nil)
        Spacer()
        Button("Refazer", systemImage: "arrow.uturn.forward") {
          Task { await store.reversion.perform(target: SessionRevert.redo(store.messages, boundary: boundary), store: store, draft: draft) }
        }.accessibilityIdentifier("revert-redo")
      }.font(.caption).foregroundStyle(theme.color(.textSecondary)).padding(.horizontal, 16).padding(.vertical, 8)
    }
  }
}
