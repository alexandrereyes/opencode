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

struct ConversationQuestionCard: View {
  @Environment(\.appTheme) private var theme
  let form: PendingForm
  let store: ConversationStore
  @State private var values: [String: JSONValue] = [:]
  @State private var custom: [String: String] = [:]
  #if os(macOS)
  /// Each answer field takes the keyboard when its count goes up (Return from the question before).
  @State private var focusRequests: [String: Int] = [:]
  #else
  @FocusState private var focus: String?
  #endif
  private var reply: QuestionReply { QuestionReply(form: form, values: values) }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(
        form.title == "Questions" ? "Uma pergunta para você" : form.title,
        systemImage: "questionmark.bubble"
      )
      .appFont(.preview, weight: .semibold).foregroundStyle(theme.color(.info))
      ForEach(form.fields.filter { QuestionReply.visible($0, values: reply.answer) }) { field in
        VStack(alignment: .leading, spacing: 10) {
          if let title = field.title { Text(title).appFont(.preview, weight: .semibold) }
          if let description = field.description { Text(description).appFont(.preview) }
          ForEach(field.options ?? []) { option in
            Button {
              if field.type == .multiselect {
                let selected = values[field.key]?.array ?? []
                values[field.key] = .array(
                  selected.contains(.string(option.value))
                    ? selected.filter { $0 != .string(option.value) }
                    : selected + [.string(option.value)])
              } else {
                values[field.key] = .string(option.value)
              }
            } label: {
              HStack(spacing: 10) {
                Image(
                  systemName: selected(option.value, field: field)
                    ? (field.type == .multiselect
                      ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (field.type == .multiselect ? "square" : "circle")
                )
                .foregroundStyle(
                  theme.color(selected(option.value, field: field) ? .primary : .textSecondary))
                VStack(alignment: .leading, spacing: 3) {
                  Text(option.label).appFont(.preview, weight: .medium)
                  if let description = option.description {
                    Text(description).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                  }
                }
                Spacer()
              }.padding(11).background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).accessibilityAddTraits(
              selected(option.value, field: field) ? .isSelected : [])
          }
          // An answer field has no send button of its own: the form sends only through Enviar. Return answers there
          // (`returned`).
          if field.type == .string && (field.custom == true || field.options == nil) {
            let text = Binding(
              get: {
                let text = values[field.key]?.string ?? ""
                return field.options?.contains { $0.value == text } == true ? "" : text
              }, set: { values[field.key] = .string($0) })
            #if os(macOS)
            // The Mac composer's answer mode: the microphone only, Shift+Return breaks the line, Esc leaves.
            MacReplyComposer(store: store, text: text, placeholder: "Outra resposta…",
              focusRequest: focusRequests[field.key] ?? 0, submit: { returned(field) })
              .padding(11).background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 9))
            #else
            TextField("Outra resposta…", text: text)
              .focused($focus, equals: field.key)
              .submitLabel(reply.onReturn(in: form, from: field.key) == .send ? .send : .next)
              .onSubmit { returned(field) }
              .appFont(.preview).padding(11).background(
                theme.color(.surface), in: RoundedRectangle(cornerRadius: 9))
              .accessibilityIdentifier("question-answer-\(field.key)")
            #endif
          }
          if field.type == .multiselect && field.custom == true {
            ForEach(
              (values[field.key]?.array ?? []).compactMap(\.string).filter { value in
                !(field.options ?? []).contains { $0.value == value }
              }, id: \.self
            ) { value in
              HStack {
                Text(value).appFont(.preview)
                Spacer()
                Button("Remover", systemImage: "xmark") {
                  values[field.key] = .array(
                    (values[field.key]?.array ?? []).filter { $0 != .string(value) })
                }.labelStyle(.iconOnly)
              }
            }
            HStack {
              let text = Binding(get: { custom[field.key] ?? "" }, set: { custom[field.key] = $0 })
              #if os(macOS)
              MacReplyComposer(store: store, text: text, placeholder: "Outra resposta…",
                focusRequest: focusRequests[field.key] ?? 0, submit: { returned(field) })
              #else
              TextField("Outra resposta…", text: text)
                .focused($focus, equals: field.key)
                .submitLabel(.next)
                .onSubmit { returned(field) }
                .accessibilityIdentifier("question-answer-\(field.key)")
              #endif
              Button("Adicionar") { addCustom(field) }.disabled(
                (custom[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.appFont(.preview).padding(11).background(
              theme.color(.surface), in: RoundedRectangle(cornerRadius: 9))
          }
          if field.type != .string && field.type != .multiselect {
            Text("Este tipo de pergunta ainda não é compatível.").appFont(.caption).foregroundStyle(
              theme.color(.warning))
          }
        }
      }
      HStack(spacing: 10) {
        Spacer()
        Button("Descartar") { Task { await store.dismiss(form) } }.buttonStyle(
          RequestButtonStyle(filled: false))
        Button("Enviar", action: send)
          .buttonStyle(RequestButtonStyle(filled: true)).disabled(
            reply.answer.isEmpty || !reply.valid(for: form))
      }
    }
    .foregroundStyle(theme.color(.text)).padding(16)
    .fixedSize(horizontal: false, vertical: true)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 15))
    .overlay {
      RoundedRectangle(cornerRadius: 15).strokeBorder(
        theme.color(.info).opacity(0.4), lineWidth: 0.7)
    }
    .disabled(store.acting.contains(form.id))
  }
  private func send() {
    guard !reply.answer.isEmpty, reply.valid(for: form), !store.acting.contains(form.id) else { return }
    Task { await store.reply(form, answer: reply) }
  }
  /// Return in an answer field. A multiple choice's own answer with text adds it (Adicionar); otherwise Return sends
  /// the form once every question shown is answered, or goes to the next unanswered one (`QuestionReply.onReturn`).
  private func returned(_ field: PendingForm.Field) {
    if field.type == .multiselect, !(custom[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      addCustom(field)
      return focusAnswer(field.key)
    }
    switch reply.onReturn(in: form, from: field.key) {
    case .send: send()
    case .next(let key): focusAnswer(key)
    case .stay: focusAnswer(field.key)
    }
  }
  /// The keyboard goes to that question's answer field; a question with options only leaves it.
  private func focusAnswer(_ key: String) {
    let typed = form.fields.first { $0.key == key }.map { field in
      field.type == .string ? field.custom == true || field.options == nil : field.type == .multiselect && field.custom == true
    } ?? false
    #if os(macOS)
    if typed { focusRequests[key, default: 0] += 1 } else { NSApp.keyWindow?.makeFirstResponder(nil) }
    #else
    focus = typed ? key : nil
    #endif
  }
  private func addCustom(_ field: PendingForm.Field) {
    let text = (custom[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let selected = values[field.key]?.array ?? []
    if !selected.contains(.string(text)) { values[field.key] = .array(selected + [.string(text)]) }
    custom[field.key] = ""
  }
  private func selected(_ option: String, field: PendingForm.Field) -> Bool {
    field.type == .multiselect
      ? values[field.key]?.array?.contains(.string(option)) == true
      : values[field.key] == .string(option)
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
