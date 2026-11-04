import OpenCodeKit
import SwiftUI

/// An agent's question being answered in the composer's place (Alexandre, 04/11, mocks A and B), kept by its
/// conversation's store while the form waits: the question shown (‹ › keep every other one as it was answered), the
/// chat's composer brought back (Escrever no chat), the iPhone's enlarged sheet, a single choice's own answer kept
/// while an option is marked instead, and the answer's editor: one draft of the composer's own editor, with its
/// dictation, shared by the form's questions and by A and B. The answers themselves are the form's
/// `QuestionDraftSync`, as before; nothing here writes to the server but that draft and Responder.
@MainActor @Observable final class QuestionAnswering {
  let form: PendingForm
  @ObservationIgnored let sync: QuestionDraftSync
  @ObservationIgnored private weak var store: ConversationStore?
  /// The question shown, by key; the first visible one when unset or hidden by an answer.
  var current: String?
  /// Escrever no chat: the conversation's composer is back with its draft, the question waits above it.
  var chatting = false
  /// iPhone: the question in its own sheet (Ampliar pergunta).
  var expanded = false
  /// The answer's field takes the keyboard (the Mac's) each time this goes up.
  var focusRequest = 0
  /// What was typed in a single choice's own answer before an option was marked: the draft keeps one value, the
  /// option, and this text stays in the field (sent only if the option is unmarked or the text typed again).
  var typed: [String: String] = [:]
  @ObservationIgnored private(set) lazy var editor: ConversationDraft = {
    #if os(macOS)
    let editor = MacReplyComposer.scratch()
    #else
    let editor = ConversationDraft.scratch()
    #endif
    // Where its dictation records.
    try? FileManager.default.createDirectory(at: editor.persistence.directory, withIntermediateDirectories: true)
    // A dictation lands in the answer of the question it was made for even with no field on screen (Escrever no
    // chat, the iPhone's sheet opening or closing): the fields only show it. ‹ › wait for it, so that question is
    // still the one shown.
    let land = editor.recording.receive
    editor.recording.receive = { [weak self, weak editor] edits in
      await land(edits)
      guard let self, let editor, let field = self.field else { return }
      self.type(editor.document.text, in: field)
    }
    return editor
  }()

  init(form: PendingForm, store: ConversationStore) {
    self.form = form
    self.store = store
    sync = store.questionDrafts.sync(form)
  }

  var reply: QuestionReply { QuestionReply(form: form, values: sync.state.values) }
  var fields: [PendingForm.Field] { form.fields.filter { QuestionReply.visible($0, values: reply.answer) } }
  var field: PendingForm.Field? { fields.first { $0.key == current } ?? fields.first }
  var position: Int { field.flatMap { field in fields.firstIndex { $0.key == field.key } } ?? 0 }
  /// A dictation under way (recording, paused or transcribing) lands in this question: it stays until then.
  var dictating: Bool { editor.recording.visible }
  var sending: Bool { store?.acting.contains(form.id) == true }
  /// What Return, the editor's action and the primary button do now (`QuestionReply.onReturn`).
  var next: QuestionReturn {
    guard let field else { return .stay }
    return reply.onReturn(in: form, from: field.key)
  }

  /// ‹ and ›: the other questions keep their answers, marked and typed alike.
  func move(_ offset: Int) {
    let target = position + offset
    guard !dictating, fields.indices.contains(target) else { return }
    current = fields[target].key
  }

  func selected(_ option: PendingForm.Field.Option, in field: PendingForm.Field) -> Bool {
    field.type == .multiselect
      ? sync.state.values[field.key]?.array?.contains(.string(option.value)) == true
      : sync.state.values[field.key] == .string(option.value)
  }

  /// A marked option is unmarked by a second tap: a single choice's own answer, if one was typed, comes back.
  func choose(_ option: PendingForm.Field.Option, in field: PendingForm.Field) {
    if field.type == .multiselect {
      let selected = sync.state.values[field.key]?.array ?? []
      sync.choose(field.key, .array(selected.contains(.string(option.value))
        ? selected.filter { $0 != .string(option.value) } : selected + [.string(option.value)]))
      return
    }
    if selected(option, in: field) {
      let own = typed[field.key] ?? ""
      return sync.choose(field.key, own.isEmpty ? nil : .string(own))
    }
    if let value = sync.state.values[field.key]?.string, !marked(value, in: field) { typed[field.key] = value }
    sync.choose(field.key, .string(option.value))
  }

  /// The answer field's text for a question: a multiple choice's item being typed, a single choice's own answer
  /// (kept under a marked option), or the answer itself.
  func text(_ field: PendingForm.Field) -> String {
    if field.type == .multiselect { return sync.state.custom[field.key] ?? "" }
    let value = sync.state.values[field.key]?.string ?? ""
    return marked(value, in: field) ? typed[field.key] ?? "" : value
  }

  /// Typing (or dictation) in the answer field. In a single choice it replaces a marked option; emptied, the option
  /// stays marked.
  func type(_ text: String, in field: PendingForm.Field) {
    guard text != self.text(field) else { return }
    if field.type == .multiselect { return sync.typeCustom(field.key, text) }
    if field.options != nil { typed[field.key] = text }
    if text.isEmpty, marked(sync.state.values[field.key]?.string ?? "", in: field) { return }
    sync.type(field.key, text)
  }

  /// A multiple choice's own item: the typed text joins the marked options.
  func add(_ field: PendingForm.Field) {
    let text = (sync.state.custom[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let selected = sync.state.values[field.key]?.array ?? []
    sync.set(field.key, value: selected.contains(.string(text)) ? sync.state.values[field.key]
      : .array(selected + [.string(text)]), custom: nil)
  }

  func remove(_ item: String, from field: PendingForm.Field) {
    sync.choose(field.key, .array((sync.state.values[field.key]?.array ?? []).filter { $0 != .string(item) }))
  }

  /// A multiple choice's items added by hand, not among its options.
  func added(_ field: PendingForm.Field) -> [String] {
    guard field.type == .multiselect else { return [] }
    let options = Set((field.options ?? []).map(\.value))
    return (sync.state.values[field.key]?.array ?? []).compactMap(\.string).filter { !options.contains($0) }
  }

  /// Return in the answer field, its composer's action and the primary button: a multiple choice's typed item is
  /// added first; then the form is answered once every question shown is, or the next unanswered question comes.
  func advance() {
    guard let field else { return }
    if field.type == .multiselect, !(sync.state.custom[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
      return add(field)
    }
    switch next {
    case .send: send()
    case .next(let key):
      guard !dictating else { return }
      current = key
      focusRequest += 1
    case .stay: break
    }
  }

  /// Responder: the form's answer, once, with what its visible questions hold (`QuestionReply`). A failure keeps
  /// everything to try again.
  func send() {
    let reply = reply
    guard let store, !reply.answer.isEmpty, reply.valid(for: form), !sending, !dictating else { return }
    Task { await store.reply(form, answer: reply) }
  }

  /// Descartar: the form is dismissed, as the card's Descartar was.
  func dismiss() {
    guard let store else { return }
    Task { await store.dismiss(form) }
  }

  private func marked(_ value: String, in field: PendingForm.Field) -> Bool {
    (field.options ?? []).contains { $0.value == value }
  }
}

extension PendingForm.Field {
  /// It takes typed text: a question without options or with its own answer, or a multiple choice's own items.
  var takesText: Bool { type == .string ? custom == true || options == nil : type == .multiselect && custom == true }
}

extension ConversationStore {
  /// The agents' questions waiting in this conversation and its subagents, as the transcript lists them.
  var questions: [PendingForm] { (family?.forms ?? []).filter { $0.metadata?["kind"]?.string == "question" } }
  /// The question the composer answers.
  var answeringForm: PendingForm? { questions.first { $0.id == answeringID } ?? questions.first }

  func answering(_ form: PendingForm) -> QuestionAnswering {
    if let existing = answerings[form.id] { return existing }
    let created = QuestionAnswering(form: form, store: self)
    answerings[form.id] = created
    return created
  }

  /// Forms no longer waiting (answered, dismissed, gone) leave nothing: their answer's editor and its files go.
  func forgetAnswering(keeping ids: [String]) {
    for (id, gone) in answerings where !ids.contains(id) {
      answerings[id] = nil
      if answeringID == id { answeringID = nil }
      Task { try? await gone.editor.discard() }
    }
  }

  /// Who asked: the subagent that did, or the conversation's agent when it has one.
  func asker(_ form: PendingForm) -> String? {
    if form.sessionID != id, let child = children.first(where: { $0.id == form.sessionID }) {
      return child.title ?? child.agent ?? "Subagente"
    }
    return session?.agent
  }
}

/// The agent's question in the composer's place (mock A): one question at a time, with ‹ › and its place among the
/// form's; its options, marked with a tap; one answer field, the composer's own editor (dictation and its review
/// included); and Responder, which answers the form, never the chat. Escrever no chat brings the composer back with
/// its draft untouched; the iPhone's Ampliar pergunta opens the same answer in its own sheet (mock B).
struct QuestionComposer: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  @Bindable var answering: QuestionAnswering
  /// The chat's draft, only to say it is kept.
  let chat: ConversationDraft
  /// The conversation's height: the options' band takes part of it, less with the keyboard up.
  let room: CGFloat
  @State private var optionsHeight: CGFloat = 0

  /// The options' part of the conversation's height (the Mac has no keyboard to leave room for).
  #if os(macOS)
  private static let share = 0.5
  #else
  private static let share = 0.36
  #endif
  /// The iPhone's keyboard is up: the question keeps its title (the sheet shows the rest) and a narrower band.
  private var typing: Bool {
    #if os(iOS)
    answering.editor.focused
    #else
    false
    #endif
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      QuestionHeader(store: store, answering: answering, sheet: false)
      if !typing, chat.hasText || !chat.attachments.isEmpty {
        Label("Rascunho do chat guardado", systemImage: "tray.and.arrow.down").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).accessibilityIdentifier("question-chat-kept")
      }
      if let field = answering.field {
        QuestionPrompt(field: field, sheet: false, typing: typing)
        // The options take their own height up to a part of the conversation's (less with the keyboard), then
        // scroll in their band: the conversation above keeps its room. A definite height: beside the transcript, a
        // flexible scroll view would be squeezed.
        ScrollView {
          QuestionOptions(answering: answering, field: field)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { optionsHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize).scrollIndicators(.visible)
        .frame(height: min(optionsHeight, room * (typing ? 0.14 : Self.share)))
        #if os(iOS)
        if field.takesText && !answering.expanded { QuestionAnswerField(store: store, answering: answering, field: field) }
        #else
        if field.takesText { QuestionAnswerField(store: store, answering: answering, field: field) }
        #endif
      }
      QuestionFooter(answering: answering)
    }
    .padding(14)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 18))
    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.info).opacity(0.55), lineWidth: 1) }
    .accessibilityElement(children: .contain).accessibilityIdentifier("question-composer")
    .disabled(answering.sending)
    .task(id: answering.form.id) { await answering.sync.load() }
    #if os(iOS)
    .sheet(isPresented: $answering.expanded) { QuestionSheet(store: store, answering: answering) }
    #endif
  }
}

/// The composer while the chat is back (Escrever no chat): the question still waits, one tap away.
struct QuestionWaitingBar: View {
  @Environment(\.appTheme) private var theme
  let answering: QuestionAnswering
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "questionmark.bubble").foregroundStyle(theme.color(.info))
      VStack(alignment: .leading, spacing: 2) {
        Text("Pergunta do agente esperando").appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.info))
        Text(answering.field?.title ?? answering.form.preview).appFont(.caption).lineLimit(1)
          .foregroundStyle(theme.color(.textSecondary))
      }
      Spacer(minLength: 8)
      Button("Responder") { answering.chatting = false }.buttonStyle(QuestionButtonStyle(filled: true))
        .accessibilityIdentifier("question-resume")
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 14))
    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.info).opacity(0.4), lineWidth: 0.7) }
    .accessibilityElement(children: .contain).accessibilityIdentifier("question-waiting")
    .task(id: answering.form.id) { await answering.sync.load() }
  }
}

/// Who asked, Escrever no chat, the iPhone's Ampliar pergunta and Descartar.
private struct QuestionHeader: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let answering: QuestionAnswering
  let sheet: Bool
  var body: some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Label("Pergunta do agente", systemImage: "questionmark.bubble").appFont(.secondary, weight: .semibold)
          .foregroundStyle(theme.color(.info)).lineLimit(1)
        if let asker = store.asker(answering.form) {
          Text(asker).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }
      }
      .layoutPriority(1)
      Spacer(minLength: 4)
      if !sheet {
        Button("Escrever no chat", systemImage: "text.bubble") { answering.chatting = true }
          #if os(iOS)
          .labelStyle(.iconOnly).frame(width: 44, height: 44)
          #endif
          .accessibilityIdentifier("question-write-chat")
        #if os(iOS)
        Button("Ampliar pergunta", systemImage: "arrow.up.left.and.arrow.down.right") {
          answering.editor.focused = false
          answering.expanded = true
        }
        .labelStyle(.iconOnly).frame(width: 44, height: 44).accessibilityIdentifier("question-expand")
        #endif
      }
      Menu {
        Button("Descartar pergunta", systemImage: "xmark.circle", role: .destructive) { answering.dismiss() }
      } label: {
        Image(systemName: "ellipsis").frame(width: 32, height: 32)
          #if os(iOS)
          .frame(width: 44, height: 44)
          #endif
      }
      .menuIndicator(.hidden).accessibilityLabel("Mais").accessibilityIdentifier("question-more")
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
  }
}

/// The question's title and its text: a few lines in the composer's place (the transcript's card and the iPhone's
/// sheet show it all), all of it in the sheet.
private struct QuestionPrompt: View {
  @Environment(\.appTheme) private var theme
  let field: PendingForm.Field
  let sheet: Bool
  var typing = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title = field.title {
        Text(title).appFont(sheet ? .title : .heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
          .lineLimit(typing ? 2 : nil)
          .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
      }
      if let description = field.description, !typing || field.title == nil {
        Text(description).appFont(.body).foregroundStyle(theme.color(.text))
          .lineLimit(sheet ? nil : typing ? 2 : 3).fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
  }
}

/// The options, marked with a tap (a second tap unmarks), each whole whatever its length, and a multiple choice's
/// items added by hand.
private struct QuestionOptions: View {
  @Environment(\.appTheme) private var theme
  let answering: QuestionAnswering
  let field: PendingForm.Field
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(field.options ?? []) { option in
        let selected = answering.selected(option, in: field)
        Button {
          #if os(iOS)
          // Marking an option leaves the answer field: no keyboard without a field to type in.
          answering.editor.focused = false
          #endif
          answering.choose(option, in: field)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: selected
              ? (field.type == .multiselect ? "checkmark.square.fill" : "largecircle.fill.circle")
              : (field.type == .multiselect ? "square" : "circle"))
              .foregroundStyle(theme.color(selected ? .info : .textSecondary))
            VStack(alignment: .leading, spacing: 3) {
              Text(option.label).appFont(.body, weight: .medium).foregroundStyle(theme.color(.textStrong))
              if let description = option.description {
                Text(description).appFont(.secondary).foregroundStyle(theme.color(.textSecondary))
              }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          .padding(12).frame(minHeight: 44)
          .background(theme.color(selected ? .highlight : .background), in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(theme.color(selected ? .info : .border), lineWidth: selected ? 1.2 : 0.7)
          }
          .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("question-option-" + option.value)
      }
      ForEach(answering.added(field), id: \.self) { item in
        HStack {
          Text(item).appFont(.body)
          Spacer()
          Button("Remover", systemImage: "xmark") { answering.remove(item, from: field) }.labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 12).foregroundStyle(theme.color(.text))
        .background(theme.color(.background), in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }
}

/// The one answer field: the composer's own editor over the answer's draft (the iPhone's `ComposerEditor` in its
/// answer mode, the Mac's `MacReplyComposer`), dictation and its review included. It follows the question shown;
/// its action and Return answer or go on (`QuestionAnswering.advance`), never send to the chat.
private struct QuestionAnswerField: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let answering: QuestionAnswering
  let field: PendingForm.Field
  private var placeholder: String {
    field.type == .multiselect ? "Outra opção…" : field.options == nil ? "Sua resposta…" : "Outra resposta…"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if field.type == .string, field.options != nil, !answering.text(field).isEmpty,
        answering.sync.state.values[field.key].flatMap(\.string).map({ value in
          (field.options ?? []).contains { $0.value == value }
        }) == true
      {
        Text("Vale a opção marcada; escreva aqui para responder com o seu texto.").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary))
      }
      editor
    }
  }
  #if os(iOS)
  private var editor: some View {
    ComposerEditor(
      store: store, draft: answering.editor, expanded: false,
      comment: ComposerComment(placeholder: placeholder, reservedBytes: 0, commit: { answering.advance() }, answer: true)
    ) {}
    .onAppear(perform: receive)
    .onChange(of: field.key) { receive() }
    // Another device's change, or an option marked: the field shows the answer as it now is.
    .onChange(of: answering.text(field)) { receive() }
    .onChange(of: answering.editor.contentRevision) {
      answering.type(answering.editor.document.text, in: field)
    }
    .onChange(of: answering.editor.focused) { _, focused in
      answering.sync.focused = focused ? field.key : nil
    }
  }
  /// The question's answer into the editor, caret at the end, unless it already holds it (being typed).
  private func receive() {
    let text = answering.text(field)
    guard answering.editor.document.text != text else { return }
    answering.editor.text = NSAttributedString(string: text)
    answering.editor.selection = NSRange(location: (text as NSString).length, length: 0)
  }
  #else
  private var editor: some View {
    MacReplyComposer(
      store: store, text: Binding(get: { answering.text(field) }, set: { answering.type($0, in: field) }),
      placeholder: placeholder, focusRequest: answering.focusRequest, submit: { answering.advance() },
      focusChanged: { focused in answering.sync.focused = focused ? field.key : nil }, editor: answering.editor)
      .padding(11).background(theme.color(.background), in: RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }
  #endif
}

/// ‹ n de N › and the primary button: Próxima while another question is unanswered, then Responder. In the sheet
/// the steps sit above Agora não and the button.
private struct QuestionFooter: View {
  @Environment(\.appTheme) private var theme
  let answering: QuestionAnswering
  var close: (() -> Void)? = nil
  var body: some View {
    if let close {
      VStack(spacing: 6) {
        HStack(spacing: 6) {
          steps
          Spacer(minLength: 0)
        }
        HStack(spacing: 10) {
          Button("Agora não", action: close).buttonStyle(QuestionButtonStyle(filled: false))
            .accessibilityIdentifier("question-sheet-close")
          primary.frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
    } else {
      HStack(spacing: 6) {
        steps
        Spacer(minLength: 8)
        primary
      }
      .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
    }
  }
  @ViewBuilder private var steps: some View {
    if answering.fields.count > 1 {
      Button("Pergunta anterior", systemImage: "chevron.left") { answering.move(-1) }
        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        .disabled(answering.position == 0 || answering.dictating).accessibilityIdentifier("question-previous")
      Text("\(answering.position + 1) de \(answering.fields.count)").appFont(.secondary).monospacedDigit()
        .foregroundStyle(theme.color(.textSecondary)).accessibilityIdentifier("question-step")
      Button("Próxima pergunta", systemImage: "chevron.right") { answering.move(1) }
        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        .disabled(answering.position >= answering.fields.count - 1 || answering.dictating)
        .accessibilityIdentifier("question-next")
    }
  }
  private var primary: some View {
    let next = answering.next
    return Button { answering.advance() } label: {
      Text(next == .send || next == .stay ? "Responder" : "Próxima").lineLimit(1).fixedSize()
        .frame(maxWidth: close == nil ? nil : .infinity)
    }
    .buttonStyle(QuestionButtonStyle(filled: true))
    .disabled(next == .stay || answering.dictating || answering.sending)
    .keyboardShortcut(.defaultAction)
    .accessibilityIdentifier("question-primary")
  }
}

/// Responder, in the question's own color: never the chat's ↑.
struct QuestionButtonStyle: ButtonStyle {
  @Environment(\.appTheme) private var theme
  @Environment(\.isEnabled) private var enabled
  var filled: Bool
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.appFont(.secondary, weight: .semibold).padding(.horizontal, 18)
      .frame(minHeight: 44)
      .foregroundStyle(theme.color(filled ? .onInfo : .text))
      .background(theme.color(filled ? .infoFill : .surface), in: Capsule())
      .overlay { if !filled { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1) } }
      .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
      .contentShape(Capsule())
  }
}

#if os(iOS)
/// Ampliar pergunta (mock B): the same answer in its own sheet, the question whole and readable, the options, the
/// answer field and ‹ n de N › with Responder fixed below the scroll. Agora não only closes it: nothing is sent,
/// dismissed or lost, and the composer's place shows the same answer.
struct QuestionSheet: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let answering: QuestionAnswering
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        QuestionHeader(store: store, answering: answering, sheet: true)
      }
      .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
      Divider().overlay(theme.color(.border))
      ScrollView {
        if let field = answering.field {
          VStack(alignment: .leading, spacing: 14) {
            QuestionPrompt(field: field, sheet: true)
            QuestionOptions(answering: answering, field: field)
            if field.takesText { QuestionAnswerField(store: store, answering: answering, field: field) }
          }
          .padding(18)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      Divider().overlay(theme.color(.border))
      QuestionFooter(answering: answering) { answering.expanded = false }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    .background(theme.color(.background))
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .accessibilityElement(children: .contain).accessibilityIdentifier("question-sheet")
  }
}
#endif
