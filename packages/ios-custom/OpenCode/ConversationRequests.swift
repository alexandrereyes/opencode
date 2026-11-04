import OpenCodeKit
import SwiftUI

struct ConversationPermissionCard: View {
  @Environment(\.appTheme) private var theme
  let request: PermissionRequest
  let store: ConversationStore
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "shield.fill").appSymbol(.navigation).foregroundStyle(theme.color(.error))
        VStack(alignment: .leading, spacing: 6) {
          Text("Quer rodar:").appFont(.preview, weight: .semibold).foregroundStyle(
            theme.color(.error))
          Text(request.resources.first ?? request.action).appFont(.caption, design: .monospaced)
          .foregroundStyle(theme.color(.text)).textSelection(.enabled)
        }
        Spacer(minLength: 0)
        Menu {
          Button("Permitir sempre") { reply(.always) }
        } label: {
          Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .plainMenuOnMac()
        .foregroundStyle(theme.color(.textSecondary)).accessibilityLabel("Mais opções de permissão")
      }
      HStack(spacing: 10) {
        Spacer()
        Button("Negar") { reply(.reject) }.buttonStyle(RequestButtonStyle(filled: false))
        Button("Permitir") { reply(.once) }.buttonStyle(RequestButtonStyle(filled: true))
      }
    }
    .padding(16).background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 15))
    .fixedSize(horizontal: false, vertical: true)
    .overlay {
      RoundedRectangle(cornerRadius: 15).strokeBorder(
        theme.color(.error).opacity(0.4), lineWidth: 0.7)
    }
    .disabled(store.acting.contains(request.id))
    .contextMenu { Button("Permitir sempre") { reply(.always) } }
  }
  private func reply(_ decision: PermissionReply.Decision) {
    Task { await store.reply(request, decision: decision) }
  }
}

struct RequestButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var enabled
  var filled: Bool
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.appFont(.secondary, weight: .medium).padding(.horizontal, 18).padding(
      .vertical, 11
    )
    .foregroundStyle(theme.color(filled ? .onFilledButton : .text))
    .background(theme.color(filled ? .filledButton : .surface), in: Capsule())
    .overlay { if !filled { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1) } }
    .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
  }
}

/// An agent's question in the conversation: the whole of it, to read, and where it is answered. The answer itself
/// lives in the composer's place (`QuestionComposer`, one field, Responder); this card has no field of its own, and
/// its Responder brings the answer back when the chat took the composer or another question is being answered.
struct ConversationQuestionCard: View {
  @Environment(\.appTheme) private var theme
  let form: PendingForm
  let store: ConversationStore
  var body: some View {
    let answering = store.answering(form)
    let shown = store.answeringForm?.id == form.id && !answering.chatting
    VStack(alignment: .leading, spacing: 12) {
      Label(form.title == "Questions" ? "Pergunta do agente" : form.title, systemImage: "questionmark.bubble")
        .appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.info))
      ForEach(answering.fields) { field in
        VStack(alignment: .leading, spacing: 4) {
          if let title = field.title {
            Text(title).appFont(.body, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          }
          if let description = field.description { Text(description).appFont(.body).textSelection(.enabled) }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if shown {
          Label("Responda no campo abaixo", systemImage: "arrow.down").appFont(.caption)
            .foregroundStyle(theme.color(.textSecondary))
        } else {
          Button("Responder") {
            store.answeringID = form.id
            answering.chatting = false
          }
          .buttonStyle(QuestionButtonStyle(filled: true)).accessibilityIdentifier("question-card-answer")
        }
        Spacer()
      }
    }
    .foregroundStyle(theme.color(.text)).padding(16)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 15))
    .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(theme.color(.info).opacity(0.4), lineWidth: 0.7) }
    .accessibilityElement(children: .contain).accessibilityIdentifier("question-card")
  }
}

struct ConversationTray: View {
  let store: ConversationStore
  @Bindable var draft: ConversationDraft
  /// The execution's start when the host reads it itself (the Mac samples it, so streamed deltas do not re-evaluate
  /// the tray); otherwise it is read from the messages here.
  var started: Double?? = nil
  var body: some View {
    ConversationRunTray(
      run: store.executing && !store.waiting
        ? ConversationRunTrayRun(
          model: store.modelLabel(store.session?.model).components(separatedBy: " · ").first ?? "Agente",
          started: started ?? ConversationProjection.executionStarted(store.messages, complete: !store.hasOlder),
          background: store.canBackground ? { Task { await store.background() } } : nil,
          backgroundBusy: store.acting.contains("background"),
          stop: { Task { await store.stop() } }, stopping: store.acting.contains("stop"))
        : nil,
      queue: store.queue.map { ConversationRunTrayItem(id: $0.id, text: $0.payload.displayText, actionable: store.actionable($0)) },
      editDisabled: draft.sending,
      sendNow: { item in
        guard let queued = store.queue.first(where: { $0.id == item.id }) else { return }
        Task { await store.promote(queued) }
      },
      edit: { item in
        guard let queued = store.queue.first(where: { $0.id == item.id }) else { return }
        draft.restore(queued)
        store.toast.show("Mensagem pronta para editar")
      },
      remove: { item in
        guard let queued = store.queue.first(where: { $0.id == item.id }) else { return }
        Task { await store.cancel(queued) }
      })
  }
}
