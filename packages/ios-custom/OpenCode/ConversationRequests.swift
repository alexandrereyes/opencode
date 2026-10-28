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
          if field.type == .string && (field.custom == true || field.options == nil) {
            let text = Binding(
              get: {
                let text = values[field.key]?.string ?? ""
                return field.options?.contains { $0.value == text } == true ? "" : text
              }, set: { values[field.key] = .string($0) })
            #if os(macOS)
            // Return sends, Shift+Return breaks the line, Esc leaves the field; a click focuses it.
            MacReplyField(text: text, placeholder: "Outra resposta…", submit: send)
              .padding(11).background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 9))
            #else
            TextField("Outra resposta…", text: text)
              .appFont(.preview).padding(11).background(
                theme.color(.surface), in: RoundedRectangle(cornerRadius: 9))
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
              #if os(macOS)
              MacReplyField(text: Binding(get: { custom[field.key] ?? "" }, set: { custom[field.key] = $0 }),
                placeholder: "Outra resposta…", submit: { addCustom(field) })
              #else
              TextField(
                "Outra resposta…",
                text: Binding(get: { custom[field.key] ?? "" }, set: { custom[field.key] = $0 }))
              #endif
              Button("Adicionar") {
                let text = (custom[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let selected = values[field.key]?.array ?? []
                if !selected.contains(.string(text)) {
                  values[field.key] = .array(selected + [.string(text)])
                }
                custom[field.key] = ""
              }.disabled(
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
        Button("Enviar") { Task { await store.reply(form, answer: reply) } }
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
  #if os(macOS)
  /// Return in the free answer: the same as Enviar, when the answer is complete.
  private func send() {
    guard !reply.answer.isEmpty, reply.valid(for: form), !store.acting.contains(form.id) else { return }
    Task { await store.reply(form, answer: reply) }
  }
  /// Return in a multiple choice's own answer: the same as Adicionar.
  private func addCustom(_ field: PendingForm.Field) {
    let text = (custom[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let selected = values[field.key]?.array ?? []
    if !selected.contains(.string(text)) { values[field.key] = .array(selected + [.string(text)]) }
    custom[field.key] = ""
  }
  #endif
  private func selected(_ option: String, field: PendingForm.Field) -> Bool {
    field.type == .multiselect
      ? values[field.key]?.array?.contains(.string(option)) == true
      : values[field.key] == .string(option)
  }
}

struct ConversationTray: View {
  let store: ConversationStore
  @Bindable var draft: ConversationDraft
  var body: some View {
    ConversationRunTray(
      run: store.executing && !store.waiting
        ? ConversationRunTrayRun(
          model: store.modelLabel(store.session?.model).components(separatedBy: " · ").first ?? "Agente",
          started: ConversationProjection.executionStarted(store.messages, complete: !store.hasOlder),
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
