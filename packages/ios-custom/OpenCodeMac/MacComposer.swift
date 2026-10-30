import AppKit
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat's composer on the iPhone's model (`ConversationDraft`, `ConversationStore.send`, `ComposerSources`):
/// `@` sessions, apps, agents and references, `&` files, `/` commands, `$` skills and `#` snippets open the
/// shared suggestion panel (↑/↓ or ⌃P/⌃N move, Return or Tab picks, Esc closes) and become atomic colored tokens;
/// a pasted or dropped image is cited in the text as `[image-1.png]`, like the web; `+` adds attachments; quotes
/// wait in `Citações · N`. Then the model and agent capsules and the microphone, which
/// turns into Enviar once there is something to send. Context and cache live in Contexto and the title's ring.
///
/// Return sends and Shift+Return breaks the line (the Mac chat convention). Sending while the agent works uses
/// the server's follow-up preference, like the iPhone; right-clicking Enviar offers the other delivery (Enviar
/// agora / Adicionar à fila). Dictation uses the iPhone's local recorder and Parakeet; the transcript lands in this
/// editor, where it is reviewed and sent (no review sheet), and the right Option key dictates too.
///
/// Every Mac text field is this composer (`features`): the chat's, Nova sessão's and a quote's comment, and in its
/// `reply` mode Pergunta paralela and the questions' own answers (`MacReplyComposer`).
struct MacComposer: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.voiceController) private var voice
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.macWindowRuntime) private var windowRuntime
  @Bindable var store: ConversationStore
  @Bindable var draft: ConversationDraft
  /// Inside another screen (Nova sessão): only the editor card, which that screen sends from; it shows the model,
  /// MCPs and agent itself.
  var embedded: MacComposerEmbedding? = nil
  var features = MacComposerFeatures.chat
  /// The empty field's text; the chat's by default.
  var placeholder: String? = nil
  var identifier = "conversation-composer"
  /// Beside `+` and the capsules, before the microphone (Pergunta paralela's model).
  var accessory: AnyView? = nil
  /// Sits on the card's top right corner (the chat's ↓ when the window leaves no margin for it).
  var corner: AnyView? = nil
  /// What the dictation review sees besides the draft, in place of the conversation's latest messages.
  var dictationTurns: (@MainActor () -> [DictationReview.Turn])? = nil
  @State private var owner = UUID()
  @State private var suggestionReturn = ComposerSuggestionReturn()
  @State private var highlight = ComposerSuggestionHighlight()
  @State private var picking: MacPicker?

  /// The trigger being typed, when this composer offers it.
  private var trigger: ComposerTrigger? {
    draft.trigger.flatMap { features.triggers.contains($0.character) ? $0 : nil }
  }
  private var hasContent: Bool { draft.hasText || !draft.attachments.isEmpty || !draft.quotes.isEmpty }
  private var canSubmit: Bool {
    guard !draft.recording.visible else { return false }
    if let embedded { return embedded.canSubmit }
    return hasContent && !draft.sending && !draft.importing && store.ready && store.selectedModel(draft) != nil
  }

  var body: some View {
    #if DEBUG
    let _ = MacPerf.count("MacComposer")
    #endif
    VStack(spacing: 7) {
      if let trigger {
        ComposerSuggestions(store: store, trigger: trigger, ready: suggestionReturn, highlight: highlight) {
          choose($0, replacing: trigger)
        }
      }
      if draft.replacing != nil {
        HStack {
          Label("Editando mensagem da fila", systemImage: "pencil")
          Spacer()
          Button("Cancelar edição") {
            draft.editing = nil
            draft.replacing = nil
            draft.submission = nil
          }
          .buttonStyle(.plain)
        }
        .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      if let error = draft.error ?? draft.persistenceError {
        Text(error).appFont(.caption).foregroundStyle(theme.color(.error)).frame(maxWidth: .infinity, alignment: .leading)
      }
      if !draft.quotes.isEmpty { DraftQuotesCard(draft: draft) }
      card
    }
    .onAppear {
      draft.editorOwner = owner
      draft.recording.willUseAudio = { [weak voice = voice] in voice?.state.visible != true }
      draft.useDictationReviewer(store, turns: dictationTurns)
      reviewDictation()
      registerDictationKey()
    }
    .onChange(of: draft.dictationReview) { reviewDictation() }
    .onChange(of: scenePhase) { reviewDictation() }
    .onChange(of: voice?.state.visible) { _, calling in if calling == true { draft.recording.suspend() } }
    #if DEBUG
    .task {
      // `-OpenCodeMacModelPicker`: opens Modelo e esforço and prints how long it took to show (A20).
      guard embedded == nil, MacPickerTiming.enabled, !store.isNewSession else { return }
      try? await Task.sleep(for: .seconds(3))
      MacPickerTiming.start = CACurrentMediaTime()
      picking = .model
    }
    .task {
      // `-OpenCodeMacDraft <text>` types a draft (a trigger opens the suggestion panel) and
      // `-OpenCodeMacPickSuggestion <s>` picks the panel's first item that long after, for captures.
      guard let text = MacFixture.value("-OpenCodeMacDraft") else { return }
      try? await Task.sleep(for: .seconds(1))
      draft.text = NSAttributedString(string: text)
      draft.selection = NSRange(location: (text as NSString).length, length: 0)
      draft.focused = true
      guard let delay = MacFixture.value("-OpenCodeMacPickSuggestion").flatMap(Double.init) else { return }
      try? await Task.sleep(for: .seconds(delay))
      firstSuggestion()?()
    }
    .task {
      // `-OpenCodeMacKeys "/ r down down return"`: types into the editor through AppKit's own key path, one key
      // every 0.4 s (characters, or up/down/return/tab/esc/ctrl-n/ctrl-p/newline), for quick checks without a
      // keyboard; `clear` empties the field, `paste-image` pastes a small PNG, `unchip` closes the first
      // attachment's chip, `ropt` taps the right Option key, `new-session`, `btw` and `comment` open those sheets, `wait` waits a second. Keys go to
      // the open sheet's focused composer when there is one.
      guard embedded == nil, let keys = MacFixture.value("-OpenCodeMacKeys") else { return }
      try? await Task.sleep(for: .seconds(2))
      for key in keys.split(separator: " ").map(String.init) {
        guard let text = draft.input?.textView, let main = text.window else { return }
        var window = main
        while let sheet = window.attachedSheet { window = sheet }
        if window === main {
          main.makeFirstResponder(text)
        } else if !(window.firstResponder is ComposerTextNSView), let field = MacSyntheticKey.composer(in: window.contentView) {
          window.makeFirstResponder(field)
        }
        if key == "dump" {
          for field in MacSyntheticKey.composers(in: window.contentView) + MacSyntheticKey.composers(in: main.contentView) {
            guard let scroll = field.enclosingScrollView else { continue }
            print("MacDump \(field.accessibilityIdentifier()) clip=\(scroll.contentView.bounds) doc=\(field.frame) scroll=\(scroll.frame) inset=\(scroll.contentInsets) origin=\(field.textContainerOrigin) min=\(field.minSize) max=\(field.maxSize)")
          }
          fflush(stdout)
        } else if key == "comment" {
          draft.commenting = ChatQuote(messageID: "msg_check", partID: "prt_check", text: "Trecho citado")
        } else if key == "wait" {
          try? await Task.sleep(for: .seconds(1))
        } else if key == "ropt" {
          MacSyntheticKey.rightOption(window)
        } else if key == "new-session" {
          windowRuntime?.newSession()
        } else if key == "btw" {
          windowRuntime?.askSideQuestion()
        } else if key == "paste-image" {
          let item = NSPasteboardItem()
          let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0)
          item.setData(image?.representation(using: .png, properties: [:]) ?? Data(), forType: .png)
          _ = MacAttachments.receive([item], store: store, draft: draft)
        } else if key == "clear" {
          draft.replace(NSRange(location: 0, length: draft.editorText.length), with: NSAttributedString())
        } else if key == "unchip" {
          guard let attachment = draft.attachments.first else { continue }
          MacAttachments.uncite(attachment, in: draft)
          draft.remove(attachment)
        } else {
          MacSyntheticKey.send(key, to: window)
        }
        try? await Task.sleep(for: .milliseconds(400))
      }
    }
    #endif
    .onDisappear {
      if draft.editorOwner == owner { draft.editorOwner = nil }
      draft.recording.suspend()
      MacDictationKey.shared.unregister(owner)
    }
    .modifier(MacMicrophonePermission(denied: Binding(get: { draft.recording.permissionDenied }, set: { draft.recording.permissionDenied = $0 })))
    .alert("Baixar transcrição neste Mac?", isPresented: Binding(get: { draft.recording.asksDownload }, set: { draft.recording.asksDownload = $0 })) {
      Button("Baixar por Wi-Fi") { draft.recording.transcription.download(cellular: false) }
      Button("Usar qualquer rede") { draft.recording.transcription.download(cellular: true) }
      Button("Agora não", role: .cancel) {}
    } message: { Text(TranscriptionController.downloadMessage) }
    .sheet(item: $picking) { picker in
      MacPickerSheet(picker: picker, store: store, draft: draft)
    }
    .sheet(item: $draft.commenting) { quote in
      MacQuoteCommentSheet(quote: quote, store: store, draft: draft)
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 8) {
      if features.attachments, draft.attachments.contains(where: { $0.quoteID == nil }) { attachmentRow }
      if draft.importing {
        ProgressView("Preparando anexos…").controlSize(.small).appFont(.caption)
      }
      if draft.recording.capturing || draft.recording.discarding {
        DictationRecordingPanel(recording: draft.recording, hasContent: hasContent)
      }
      if draft.recording.state == .pending { DictationPendingView(recording: draft.recording) }
      if let error = draft.recording.error, draft.recording.state != .pending {
        Text(error).appFont(.caption).foregroundStyle(theme.color(.error))
      }
      if voice?.state.visible == true {
        Text("Encerre a conversa por voz para ditar.").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
      if features.bare {
        // Inside its host's card (a question's own answer): the microphone and send beside the field.
        HStack(alignment: .center, spacing: 6) {
          editor
          action
        }
      } else {
        editor.padding(.horizontal, 4)
        HStack(spacing: 8) {
          if features.attachments { attach }
          if features.capsules {
            ComposerModelChip(label: store.modelLabel(store.selectedModel(draft)).isEmpty ? "Modelo"
              : store.modelLabel(store.selectedModel(draft))) { openModelPalette() }
              .buttonStyle(.plain).foregroundStyle(theme.color(.text))
              .help("Modelo e esforço (⌥⌘M)")
              .accessibilityIdentifier("model-picker")
            agent
          }
          accessory
          Spacer(minLength: 4)
          action
        }
      }
    }
    .padding(.horizontal, features.bare ? 0 : 12).padding(.top, features.bare ? 0 : 12)
    .padding(.bottom, features.bare ? 0 : 10)
    .background { if !features.bare { RoundedRectangle(cornerRadius: 18).fill(theme.color(.surface)) } }
    .overlay {
      if !features.bare {
        RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(store.isChild && features.capsules ? .accent : .border),
          lineWidth: store.isChild && features.capsules ? 1 : 0.7)
      }
    }
    .overlay(alignment: .topTrailing) { corner }
  }

  /// The editor draws its placeholder on its own first line, with the same font and line height as the text.
  private var editor: some View {
    MacComposerEditor(draft: draft, theme: theme, owner: owner, trigger: trigger, canSubmit: canSubmit, submit: submit,
      dictate: dictate,
      placeholder: placeholder ?? (store.isChild ? "Mensagem para o subagente…" : "Pergunte qualquer coisa…"),
      identifier: identifier, cancel: embedded?.cancel,
      firstSuggestion: firstSuggestion, moveSuggestion: { highlight.move($0) },
      attach: features.attachments ? { items in MacAttachments.receive(items, store: store, draft: draft) } : nil)
  }

  private var attach: some View {
    Menu {
      Button("Arquivos…", systemImage: "doc") { MacAttachments.choose(images: false, store: store, draft: draft) }
      Button("Imagens…", systemImage: "photo") { MacAttachments.choose(images: true, store: store, draft: draft) }
      Divider()
      Button("Mencionar arquivo (&)", systemImage: "at") { insertTrigger("&") }
    } label: {
      Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.color(.text))
        .frame(width: 28, height: 28)
        .overlay { Circle().strokeBorder(theme.color(.controlBorder), lineWidth: 0.7) }
        .contentShape(Circle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help("Adicionar arquivos ou imagens (ou arraste para a janela, ou cole)")
    .accessibilityLabel("Adicionar")
    .disabled(draft.sending || draft.importing)
  }

  @ViewBuilder private var action: some View {
    // Without a send button the microphone stays whatever the field holds.
    let sends = features.send && hasContent
    HStack(spacing: 0) {
      DictationCompactMicrophone(recording: draft.recording, hasContent: sends, available: dictationAvailable)
        .help("Clique ou segure para ditar · ⌃⌥Espaço no editor")
      DictationAction(recording: draft.recording, hasContent: sends, canSubmit: canSubmit,
        sending: draft.sending, available: dictationAvailable, submit: submit)
        .help(features.send ? "Segure para ditar, arraste para cima para travar · Return envia · Shift+Return quebra a linha"
          : "Clique ou segure para ditar, arraste para cima para travar · ⌃⌥Espaço no editor")
      .contextMenu {
        if hasContent, !draft.recording.visible, embedded == nil, store.executing {
          Button(store.preferences?.data.settings.followUpBehavior == .queue ? "Enviar agora" : "Adicionar à fila") {
            Task { await store.send(draft, alternate: true) }
          }
          .disabled(!canSubmit)
        }
      }
    }
  }

  private var dictationAvailable: Bool { voice?.state.visible != true && !draft.sending && !draft.importing }

  private func dictate() {
    guard dictationAvailable else { return }
    if draft.recording.capturing { draft.recording.finish(); return }
    draft.recording.handle(.began); draft.recording.handle(.ended)
  }

  /// The transcript lands in this editor at the caret; the editor takes the focus so it can be reviewed and sent
  /// in place (the iPhone expands its composer; the Mac has the room already).
  private func reviewDictation() {
    guard draft.dictationReview, scenePhase == .active, !draft.focusSuppressed else { return }
    draft.dictationReview = false
    draft.focused = true
  }

  /// The right Option key dictates into the composer with the focus, or into the conversation's of the front window
  /// (`MacDictationKey`).
  private func registerDictationKey() {
    let recording = draft.recording
    MacDictationKey.shared.register(MacDictationKey.Target(
      owner: owner,
      conversation: embedded == nil ? windowRuntime?.id : nil,
      editor: { [weak draft, owner] in draft?.editorOwner == owner ? draft?.input?.textView : nil },
      recording: { recording.capturing },
      dictating: { recording.cancellable },
      available: { [weak voice, weak draft] in
        voice?.state.visible != true && draft?.sending == false && draft?.importing == false
      },
      perform: { action in
        switch action {
        // The key was already held past its delay: a hold from the start, which its release finishes.
        case .begin: recording.handle(.began); recording.handle(.held)
        case .release: recording.handle(.ended)
        case .start: recording.handle(.began); recording.handle(.ended)
        case .finish: recording.finish()
        case .discard: recording.discard()
        case .cancel: recording.cancel()
        case .toggleRevision: recording.toggleRevision()
        case .none: break
        }
      }))
  }

  /// `● build ⌄`, beside the model in the same capsule: the agent of the next prompt (a subagent's and the
  /// master's are fixed). Context and cache moved to Contexto and the title's ring.
  @ViewBuilder private var agent: some View {
    let fixed = store.isChild || store.masterMode
    let label = HStack(spacing: 4) {
      Circle().fill(agentColor).frame(width: 6, height: 6)
      Text(fixed ? store.childAgentName
        : store.agents.first { $0.id == store.selectedAgent(draft) }?.name ?? store.selectedAgent(draft))
        .lineLimit(1)
      if !fixed { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
    }
    .appFont(.chrome).foregroundStyle(theme.color(.text))
    .composerCapsule(horizontal: 8)
    .frame(minHeight: 36).contentShape(Rectangle())
    if fixed {
      label.help("Agente").accessibilityElement(children: .combine)
    } else {
      Button { picking = .agent } label: { label }
        .buttonStyle(.plain).fixedSize().help("Agente").accessibilityIdentifier("agent-picker")
        .disabled(draft.sending || draft.importing)
    }
  }

  private var agentColor: Color {
    let id = store.selectedAgent(draft)
    return theme.agentColor(store.agents.first { $0.id == id }, id: id)
  }

  private var attachmentRow: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(draft.attachments.filter { $0.quoteID == nil }) { attachment in
          MacAttachmentChip(attachment: attachment, url: draft.persistence.file(attachment)) {
            // A cited image leaves the text with its chip.
            MacAttachments.uncite(attachment, in: draft)
            draft.remove(attachment)
          }
          .disabled(draft.sending || draft.importing)
        }
      }
    }
    .scrollIndicators(.never)
  }

  private func submit() {
    guard canSubmit else { return }
    if let embedded { return embedded.submit() }
    Task { await store.send(draft) }
  }

  private func insertTrigger(_ character: String) {
    let location = draft.selection.location
    draft.replace(NSRange(location: min(location, draft.editorText.length), length: 0),
      with: NSAttributedString(string: character, attributes: draft.input?.plainAttributes))
    draft.focused = true
  }

  /// Client commands act here (`/model`, `/agent`, `/btw`); everything else becomes a token.
  private func choose(_ item: ComposerSuggestion, replacing trigger: ComposerTrigger) {
    if item.token.kind == .command && item.token.value == "client" && item.token.id != "compact" {
      draft.replace(trigger.range, with: NSAttributedString())
      if item.token.id == "btw" {
        let question = draft.document.expanded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.sideQuestion = SideQuestionLaunch(text: question, submit: !question.isEmpty)
        draft.text = NSAttributedString()
        draft.selection = NSRange(location: 0, length: 0)
        return
      }
      if item.token.id == "model" { openModelPalette(); return }
      // Embedded, the host screen shows the agent picker itself.
      guard embedded == nil else { return }
      if item.token.id == "agent", !store.isChild, !store.masterMode { picking = .agent }
      return
    }
    draft.insert(item.token, replacing: trigger.range)
  }

  /// Return's and Tab's pick: the highlighted item, once loaded for the trigger still being typed.
  private func firstSuggestion() -> (() -> Void)? {
    guard let trigger else { return nil }
    if let item = highlight.selected(for: trigger) { return { choose(item, replacing: trigger) } }
    guard let first = suggestionReturn.first, first.trigger == trigger else { return nil }
    return { choose(first.item, replacing: trigger) }
  }

  private func openModelPalette() {
    guard let windowRuntime else { return }
    if embedded != nil { windowRuntime.openModelPalette(theme: theme); return }
    windowRuntime.modelPalette.open(runtime: windowRuntime, conversation: store, draft: draft, theme: theme)
  }
}

/// The editor: `ComposerInputView` bound to the draft, as the iPhone's `ComposerTextView` binds its UITextView.
/// Native edits reach the draft without re-rendering the composer; the draft's own replacements (a token, a
/// restored prompt) reach the editor through its source revision.
struct MacComposerEditor: NSViewRepresentable {
  @Bindable var draft: ConversationDraft
  let theme: AppTheme
  let owner: UUID
  /// The suggestion trigger this composer answers (`MacComposerFeatures.triggers`).
  let trigger: ComposerTrigger?
  let canSubmit: Bool
  let submit: () -> Void
  var dictate: () -> Void = {}
  var placeholder = ""
  var identifier = "conversation-composer"
  var cancel: (() -> Void)? = nil
  let firstSuggestion: () -> (() -> Void)?
  var moveSuggestion: (Int) -> Bool = { _ in false }
  /// Pasted images and files; nil where the composer takes no attachments.
  let attach: (([NSPasteboardItem]) -> Bool)?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> ComposerInputView {
    let view = ComposerInputView(frame: .zero)
    view.textView.delegate = context.coordinator
    view.textView.focusChanged = { [weak draft] focused in
      guard let draft, draft.editorOwner == owner else { return }
      // Focus changes arrive inside AppKit's responder change; publish them after it.
      DispatchQueue.main.async { if draft.focused != focused { draft.focused = focused } }
    }
    return view
  }

  func updateNSView(_ view: ComposerInputView, context: Context) {
    #if DEBUG
    MacPerf.count("MacComposerEditor")
    #endif
    _ = draft.editorRefresh
    context.coordinator.parent = self
    view.composerOwner = owner
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    if draft.editorOwner == owner { draft.input = view }
    let text = view.textView
    text.isEditable = !draft.sending
    text.submit = submit
    text.dictate = dictate
    text.canSubmit = canSubmit && trigger == nil
    text.querying = trigger != nil
    text.firstSuggestion = firstSuggestion
    text.moveSuggestion = moveSuggestion
    text.escape = { [weak draft] in draft?.dismissSuggestions() }
    text.cancel = cancel
    text.attach = attach
    text.insertionPointColor = theme.nsColor(.primary)
    text.isContinuousSpellCheckingEnabled = trigger == nil
    if text.placeholder != placeholder { text.placeholder = placeholder }
    if text.accessibilityIdentifier() != identifier { text.setAccessibilityIdentifier(identifier) }
    guard !text.hasMarkedText() else {
      view.representedRevision = -1
      return
    }
    let restyle = view.composerTheme.id != theme.id
    view.composerTheme = theme
    if view.representedDraft !== draft || view.representedRevision != draft.sourceRevision {
      view.textStorage.setAttributedString(draft.editorText)
      view.representedDraft = draft
      view.representedRevision = draft.sourceRevision
      let length = view.textStorage.length
      text.setSelectedRange(NSRange(location: min(draft.selection.location, length),
        length: min(draft.selection.length, max(0, length - draft.selection.location))))
      view.restyle()
      text.undoManager?.removeAllActions()
      context.coordinator.cited = MacAttachments.cited(in: view.textStorage)
    } else if restyle {
      view.restyle()
    }
    text.typingAttributes = view.plainAttributes
    if draft.focused, draft.editorOwner == owner, view.window != nil, view.window?.firstResponder !== text {
      DispatchQueue.main.async { [weak view] in
        guard let view, draft.focused, view.window?.firstResponder !== view.textView else { return }
        view.window?.makeFirstResponder(view.textView)
      }
    }
  }

  /// One line at least; it grows line by line up to `ComposerInputView.maximumLines` or 40% of the window, whichever
  /// is smaller (three lines at least), then the text scrolls inside the field, following the caret.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerInputView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    let height = Self.height(nsView, width: width)
    if let container = nsView.textView.textContainer, abs(container.size.width - width) < 0.5 {
      nsView.measuredHeight = height
    }
    return CGSize(width: width, height: height)
  }

  static func height(_ view: ComposerInputView, width: CGFloat) -> CGFloat {
    let line = view.lineHeight
    let window = view.window.map { max(3, floor($0.contentLayoutRect.height * 0.4 / line)) } ?? .infinity
    let maximum = line * min(ComposerInputView.maximumLines, window)
    return min(max(line, view.contentHeight(width: width)), maximum)
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MacComposerEditor
    var updating = false
    /// The attachments cited in the text after the last edit; a citation erased takes its attachment along.
    var cited: Set<String> = []
    init(_ parent: MacComposerEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard !updating, parent.draft.editorOwner == parent.owner,
        let input = (notification.object as? ComposerTextNSView)?.input else { return }
      parent.draft.receiveEditor(input)
      input.textView.typingAttributes = input.plainAttributes
      // Only a change of height asks SwiftUI to lay the window out again; most keys leave the line count alone.
      if let width = input.textView.textContainer?.size.width,
        input.measuredHeight != MacComposerEditor.height(input, width: width) {
        input.invalidateIntrinsicContentSize()
      }
      let now = MacAttachments.cited(in: input.textStorage)
      for id in cited.subtracting(now) {
        if let attachment = parent.draft.attachments.first(where: { $0.id == id }) { parent.draft.remove(attachment) }
      }
      cited = now
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !updating, parent.draft.editorOwner == parent.owner,
        let input = (notification.object as? ComposerTextNSView)?.input, input.representedDraft === parent.draft
      else { return }
      let range = input.textView.selectedRange()
      if parent.draft.selection != range { parent.draft.selection = range }
    }
  }
}

/// The composer inside another screen: when it may send, and how; Esc in the editor runs `cancel` when given.
struct MacComposerEmbedding {
  let canSubmit: Bool
  let submit: () -> Void
  var cancel: (() -> Void)? = nil
}

/// What a composer offers where it is. Dictation (the microphone, the right Option key, ⌃⌥Space), the growing and
/// scrolling field, Return/Shift+Return/Esc and the automatic corrections turned off come with every one.
struct MacComposerFeatures {
  /// The suggestion triggers that open the panel (`@` `&` `/` `$` `#`); none in a plain answer.
  var triggers: Set<String> = ["@", "&", "/", "$", "#"]
  /// `+`, images pasted or dropped and cited in the text, and the attachments' chips.
  var attachments = true
  /// The model and agent capsules (the chat's; Nova sessão shows its own below the editor).
  var capsules = true
  /// Inside its host's own card (a question's answer): no card, the microphone beside the field.
  var bare = false
  /// Its own send button (↑) once there is text. A question's answer has none: its form sends through Enviar.
  var send = true

  static let chat = MacComposerFeatures()
  static let newSession = MacComposerFeatures(capsules: false)
  /// A quote's comment: tokens and attachments, but no command, which only starts a prompt.
  static let comment = MacComposerFeatures(triggers: ["@", "&", "$", "#"], capsules: false)
  /// Pergunta paralela: plain text, typed or dictated, in a card of its own.
  static let reply = MacComposerFeatures(triggers: [], attachments: false, capsules: false)
  /// A question's own answer or a form field, inside the question's card.
  static let answer = MacComposerFeatures(triggers: [], attachments: false, capsules: false, bare: true, send: false)
}

/// A plain answer bound to a string (Pergunta paralela, a question's own answer, a form field): the composer in a
/// `reply` mode over a draft of its own that saves nothing.
struct MacReplyComposer: View {
  let store: ConversationStore
  @Binding var text: String
  let placeholder: String
  /// The field takes the keyboard each time this goes up.
  var focusRequest = 0
  var features = MacComposerFeatures.answer
  var canSubmit = true
  let submit: () -> Void
  /// Esc runs this (a sheet's Fechar); without it Esc leaves the field.
  var cancel: (() -> Void)? = nil
  /// Takes the keyboard when it appears, with the caret at the end.
  var focusOnAppear = false
  var identifier = "question-reply"
  var accessory: AnyView? = nil
  var dictationTurns: (@MainActor () -> [DictationReview.Turn])? = nil
  @State private var draft = Self.scratch()

  var body: some View {
    MacComposer(store: store, draft: draft,
      embedded: MacComposerEmbedding(canSubmit: canSubmit, submit: {
        // The host's text follows the field after SwiftUI's next update; Return may come first.
        let value = draft.document.text
        if value != text { text = value }
        submit()
      },
        cancel: cancel ?? { [weak draft] in draft?.input?.window?.makeFirstResponder(nil) }),
      features: features, placeholder: placeholder, identifier: identifier, accessory: accessory,
      dictationTurns: dictationTurns)
      .onAppear {
        // Where its dictation records (a saved draft makes it on its first save).
        try? FileManager.default.createDirectory(at: draft.persistence.directory, withIntermediateDirectories: true)
        receive(text)
        if focusOnAppear { draft.focused = true }
      }
      .onDisappear { try? FileManager.default.removeItem(at: draft.persistence.directory) }
      .onChange(of: draft.contentRevision) {
        let value = draft.document.text
        if value != text { text = value }
      }
      .onChange(of: text) { _, value in receive(value) }
      .onChange(of: focusRequest) { draft.focused = true }
  }

  private static func scratch() -> ConversationDraft {
    let draft = ConversationDraft.scratch()
    #if DEBUG
    MacSyntheticKey.fakeDictation(draft)
    #endif
    return draft
  }

  /// The host's text (cleared after sending, restored after a stop) replaces the field's, caret at the end.
  private func receive(_ value: String) {
    guard value != draft.document.text else { return }
    draft.text = NSAttributedString(string: value)
    draft.selection = NSRange(location: (value as NSString).length, length: 0)
  }
}

/// Model and effort, and the agent, chosen for the next prompt (the composer's capsule, `/model`, `/agent`).
enum MacPicker: String, Identifiable {
  case model, agent
  var id: String { rawValue }
}

private struct MacPickerSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let picker: MacPicker
  let store: ConversationStore
  let draft: ConversationDraft
  /// Built once when the sheet opens (`ModelChoices`), so rows neither search the catalog nor rebuild per frame.
  @State private var choices: [ModelChoice]

  init(picker: MacPicker, store: ConversationStore, draft: ConversationDraft) {
    self.picker = picker
    self.store = store
    self.draft = draft
    _choices = State(initialValue: picker == .model ? ModelChoices.rows(store.displayModels, providers: store.providers) : [])
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(picker == .model ? "Modelo e esforço" : "Agente").appFont(.heading, weight: .semibold)
        Spacer()
        Button("Concluído") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(16)
      ContextHairline()
      ScrollView {
        // Lazy: a gateway catalog has hundreds of models, each with its effort capsules; only the rows on screen
        // are built.
        LazyVStack(alignment: .leading, spacing: 2) {
          if picker == .model { models } else { agents }
        }
        .padding(8)
      }
    }
    .frame(width: 420, height: 460)
    #if DEBUG
    .onAppear { MacPickerTiming.appeared() }
    #endif
  }

  @ViewBuilder private var models: some View {
    let selected = store.selectedModel(draft)
    ForEach(choices) { choice in
      let variants = choice.variants
      VStack(alignment: .leading, spacing: 4) {
        row(choice.name, detail: choice.provider, checked: choice.selected(selected) && variants.isEmpty) {
          draft.model = choice.reference()
          if variants.isEmpty { dismiss() }
        }
        if !variants.isEmpty {
          HStack(spacing: 6) {
            ForEach(variants, id: \.self) { variant in
              let checked = choice.selected(selected, variant: variant)
              Button(variant) {
                draft.model = choice.reference(variant: variant)
                dismiss()
              }
              .buttonStyle(.plain).appFont(.caption, weight: checked ? .semibold : .regular)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(theme.color(checked ? .primary : .surface).opacity(checked ? 0.18 : 1), in: Capsule())
              .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 0.7) }
            }
          }
          .padding(.leading, 12).padding(.bottom, 6)
        }
      }
    }
  }

  @ViewBuilder private var agents: some View {
    ForEach(store.agents.filter { $0.hidden != true && $0.mode != "subagent" }) { agent in
      row(agent.name, detail: "", checked: agent.id == store.selectedAgent(draft),
        color: theme.agentColor(agent, id: agent.id)) {
        draft.agent = agent.id
        if !store.isNewSession, let model = agent.model { draft.model = model }
        dismiss()
      }
    }
  }

  private func row(_ title: String, detail: String, checked: Bool, color: Color? = nil,
    action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      HStack(spacing: 10) {
        if let color { AgentPixels(color: color, running: false) }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundStyle(theme.color(.text))
          if !detail.isEmpty { Text(detail).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(2) }
        }
        Spacer()
        if checked { Image(systemName: "checkmark").foregroundStyle(theme.color(.primary)) }
      }
      .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

#if DEBUG
/// A key event delivered through the window, as the keyboard would (`-OpenCodeMacKeys`).
@MainActor enum MacSyntheticKey {
  static func send(_ name: String, to window: NSWindow) {
    let named: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
      "up": (126, "\u{F700}", []), "down": (125, "\u{F701}", []), "return": (36, "\r", []), "tab": (48, "\t", []),
      "esc": (53, "\u{1B}", []), "ctrl-n": (45, "\u{0E}", .control), "ctrl-p": (35, "\u{10}", .control),
      "space": (49, " ", []), "delete": (51, "\u{7F}", []), "newline": (36, "\r", .shift),
    ]
    let (code, characters, flags) = named[name] ?? (0, name, [])
    let ignoring = name == "ctrl-n" ? "n" : name == "ctrl-p" ? "p" : characters
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoring,
      isARepeat: false, keyCode: code) else { return }
    window.sendEvent(event)
  }

  /// A tap of the right Option key, through the app's event queue where `MacDictationKey` watches it.
  static func rightOption(_ window: NSWindow) {
    for down in [true, false] {
      let flags = NSEvent.ModifierFlags(rawValue: down ? NSEvent.ModifierFlags.option.rawValue | 0x40 : 0)
      guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: DictationKeyGesture.keyCode) else { return }
      NSApp.postEvent(event, atStart: false)
    }
  }

  /// `-OpenCodeMacFakeDictation`: the fixture's fake microphone and transcription, set before `recording` is made.
  static func fakeDictation(_ draft: ConversationDraft) {
    guard MacLaunch.fixture, ProcessInfo.processInfo.arguments.contains("-OpenCodeMacFakeDictation"),
      draft.recordingFactory == nil else { return }
    let transcription = TranscriptionController(source: DictationFixtureSource(), engine: DictationFixtureEngine(),
      monitorsNetwork: false)
    draft.recordingFactory = {
      VoiceRecordingComposer(file: $0, capture: DictationFixtureCapture(), transcription: transcription)
    }
  }

  static func composers(in view: NSView?) -> [ComposerTextNSView] {
    guard let view else { return [] }
    if let field = view as? ComposerTextNSView { return [field] }
    return view.subviews.flatMap { composers(in: $0) }
  }

  static func composer(in view: NSView?) -> ComposerTextNSView? {
    guard let view else { return nil }
    if let field = view as? ComposerTextNSView { return field }
    return view.subviews.lazy.compactMap { composer(in: $0) }.first
  }
}

/// The model picker's opening time: from the request to the sheet's appearance, then to the end of the first main
/// run-loop turn after it (its first layout and drawing), printed as `MacPicker …` for `script` runs.
@MainActor enum MacPickerTiming {
  static let enabled = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacModelPicker")
  static var start: CFTimeInterval?
  static func appeared() {
    guard let start else { return }
    let appear = (CACurrentMediaTime() - start) * 1000
    DispatchQueue.main.async {
      DispatchQueue.main.async {
        print(String(format: "MacPicker appear=%.0fms shown=%.0fms", appear, (CACurrentMediaTime() - start) * 1000))
        fflush(stdout)
        MacPickerTiming.start = nil
      }
    }
  }
}
#endif

private struct MacAttachmentChip: View {
  @Environment(\.appTheme) private var theme
  let attachment: DraftAttachment
  let url: URL
  let remove: () -> Void
  @State private var image: CGImage?
  var body: some View {
    HStack(spacing: 7) {
      if let image {
        Image(decorative: image, scale: 2).resizable().scaledToFill().frame(width: 30, height: 30).clipped()
          .clipShape(RoundedRectangle(cornerRadius: 5))
      } else {
        Image(systemName: attachment.mime.hasPrefix("image/") ? "photo" : "doc").frame(width: 20)
      }
      Text(attachment.name).appFont(.caption).lineLimit(1).frame(maxWidth: 140)
      Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Remover \(attachment.name)")
    }
    .foregroundStyle(theme.color(.textSecondary)).padding(5)
    .background(theme.color(.codeSurface), in: RoundedRectangle(cornerRadius: 9))
    .task(id: url) {
      guard attachment.mime.hasPrefix("image/") else { return }
      image = await Task.detached {
        (try? Data(contentsOf: url)).flatMap { AttachmentImage.thumbnail($0, maxPixelSize: 90) }
      }.value
    }
  }
}

/// Attachments from the `+` panel, a drop on the window or a paste, imported through the shared
/// `ConversationStore.importAttachment` (the draft's 25 MiB limit, JPEG/PNG preparation).
@MainActor enum MacAttachments {
  static func choose(images: Bool, store: ConversationStore, draft: ConversationDraft) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    if images { panel.allowedContentTypes = [.image] }
    guard panel.runModal() == .OK else { return }
    importFiles(panel.urls, store: store, draft: draft)
  }

  /// Files chosen with `+` arrive as attachments without a citation, like the web's picker; images pasted or
  /// dropped (`cite`) are cited in the text.
  static func importFiles(_ urls: [URL], cite: Bool = false, store: ConversationStore, draft: ConversationDraft) {
    guard !urls.isEmpty else { return }
    Task {
      draft.importing = true
      defer { draft.importing = false }
      for url in urls {
        do {
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          guard size <= AttachmentEncoding.draftLimit else { throw AttachmentError.tooLarge }
          let data = try await Task.detached { try Data(contentsOf: url) }.value
          let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
          if cite, mime.hasPrefix("image/") {
            await importCited(data, name: url.lastPathComponent, mime: mime, store: store, draft: draft)
          } else {
            await store.importAttachment(data, name: url.lastPathComponent, mime: mime, draft: draft)
          }
        } catch {
          store.toast.show(error.localizedDescription, kind: .error)
        }
      }
    }
  }

  /// Pasted images (screenshots) and files. Images are cited at the caret, like the web's paste.
  static func receive(_ items: [NSPasteboardItem], store: ConversationStore, draft: ConversationDraft) -> Bool {
    let files = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
    if !files.isEmpty {
      importFiles(files, cite: true, store: store, draft: draft)
      return true
    }
    let images = items.compactMap { item -> (Data, String)? in
      if let png = item.data(forType: .png) { return (png, "png") }
      if let jpeg = item.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) { return (jpeg, "jpg") }
      if let tiff = item.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        return (png, "png")
      }
      return nil
    }
    guard !images.isEmpty else { return false }
    Task {
      draft.importing = true
      defer { draft.importing = false }
      for (data, ext) in images {
        await importCited(data, name: "image.\(ext)", mime: ext == "png" ? "image/png" : "image/jpeg",
          store: store, draft: draft)
      }
    }
    return true
  }

  /// Imports an image under a name unique in the draft and cites it at the caret as `[name]`.
  static func importCited(_ data: Data, name: String, mime: String, store: ConversationStore,
    draft: ConversationDraft) async
  {
    let unique = citedName(name, mime: mime, existing: draft.attachments.map(\.name))
    guard let attachment = await store.importAttachment(data, name: unique, mime: mime, draft: draft) else { return }
    cite(attachment, in: draft)
  }

  /// The citation token at the caret, with a space before it when glued to a word (the web's insertion boundaries).
  static func cite(_ attachment: DraftAttachment, in draft: ConversationDraft) {
    let text = draft.editorText.string as NSString
    let location = min(draft.selection.location, text.length)
    var range = NSRange(location: location, length: min(draft.selection.length, text.length - location))
    if location > 0, let scalar = UnicodeScalar(text.character(at: location - 1)),
      !CharacterSet.whitespacesAndNewlines.contains(scalar), !"([{".unicodeScalars.contains(scalar)
    {
      draft.replace(range, with: NSAttributedString(string: " ", attributes: draft.input?.plainAttributes))
      range = NSRange(location: location + 1, length: 0)
    }
    draft.insert(ComposerToken(kind: .attachment, id: attachment.id, text: "[\(attachment.name)]"), replacing: range)
  }

  /// Removes the attachment's citation from the text (its chip was closed), with the space after it.
  static func uncite(_ attachment: DraftAttachment, in draft: ConversationDraft) {
    let text = draft.editorText
    var found: NSRange?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
      guard let token = (value as? ComposerTokenAttachment)?.token, token.kind == .attachment,
        token.id == attachment.id else { return }
      found = range
      stop.pointee = true
    }
    guard var range = found else { return }
    let string = text.string as NSString
    if NSMaxRange(range) < string.length, string.character(at: NSMaxRange(range)) == 32 { range.length += 1 }
    draft.replace(range, with: NSAttributedString())
  }

  /// The attachment IDs cited in an editor text.
  static func cited(in text: NSAttributedString) -> Set<String> {
    var ids: Set<String> = []
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
      if let token = (value as? ComposerTokenAttachment)?.token, token.kind == .attachment { ids.insert(token.id) }
    }
    return ids
  }

  /// The web's `assignAttachmentFilenames`: a safe file name, generic ones (`image`, `Screenshot`, `clipboard`…)
  /// numbered from `image-1`, and unique among the draft's attachments (case-insensitive).
  static func citedName(_ name: String, mime: String, existing: [String]) -> String {
    var used = Set(existing.map { $0.lowercased() })
    let unsafe = CharacterSet(charactersIn: "<>:\"/\\|?*[]").union(.controlCharacters)
    let last = name.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? ""
    let clean = String(String.UnicodeScalarView(last.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
      .trimmingCharacters(in: .whitespaces)
    let file = clean.isEmpty ? "image" : clean
    let dot = (file as NSString).range(of: ".", options: .backwards).location
    let hasExtension = dot != NSNotFound && dot > 0
    let fallback = ["image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][mime] ?? "png"
    let ext = hasExtension ? (file as NSString).substring(from: dot + 1).lowercased() : fallback
    let base = hasExtension ? (file as NSString).substring(to: dot) : file
    let generic = base.range(of: #"^(?:image|screenshot|screen[-_ ]?shot|clipboard|pasted[-_ ]?image|untitled|unknown|file|blob)(?:[-_ ]?\(?\d+\)?)?$"#,
      options: [.regularExpression, .caseInsensitive]) != nil
    let root = generic ? "image" : base
    var index = generic ? 1 : 0
    var candidate = "\(root)\(index > 0 ? "-\(index)" : "").\(ext)"
    while used.contains(candidate.lowercased()) {
      index = index == 0 ? 2 : index + 1
      candidate = "\(root)-\(index).\(ext)"
    }
    used.insert(candidate.lowercased())
    return candidate
  }

  /// Files and images dropped on the conversation.
  static func receive(_ providers: [NSItemProvider], store: ConversationStore, draft: ConversationDraft) {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in importFiles([url], cite: true, store: store, draft: draft) }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
          guard let data else { return }
          Task { @MainActor in await importCited(data, name: "image.png", mime: "image/png", store: store, draft: draft) }
        }
      }
    }
  }
}
