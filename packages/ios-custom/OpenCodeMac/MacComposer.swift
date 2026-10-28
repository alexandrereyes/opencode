import AppKit
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat's composer on the iPhone's model (`ConversationDraft`, `ConversationStore.send`, `ComposerSources`):
/// `@` sessions, apps, agents and references, `!` files, `/` commands, `$` skills and `#` snippets open the
/// shared suggestion panel and become atomic colored tokens; `+`, dragging onto the window and pasting add
/// attachments; quotes wait in `Citações · N`. Then the model and MCP capsules and the microphone, which turns into
/// Enviar once there is something to send; below, `● build ⌄ · Contexto · Cache`.
///
/// Return sends and Shift+Return breaks the line (the Mac chat convention). Sending while the agent works uses
/// the server's follow-up preference, like the iPhone; right-clicking Enviar offers the other delivery (Enviar
/// agora / Adicionar à fila). Dictation uses the iPhone's local recorder, Parakeet and review flow.
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
  var reviewing = false
  @State private var owner = UUID()
  @State private var suggestionReturn = ComposerSuggestionReturn()
  @State private var picking: MacPicker?
  @State private var mcpOpen = false

  private var hasContent: Bool { draft.hasText || !draft.attachments.isEmpty || !draft.quotes.isEmpty }
  private var canSubmit: Bool {
    guard !draft.recording.visible else { return false }
    if let embedded { return embedded.canSubmit }
    return hasContent && !draft.sending && !draft.importing && store.ready && store.selectedModel(draft) != nil
  }

  var body: some View {
    VStack(spacing: 7) {
      if let trigger = draft.trigger {
        ComposerSuggestions(store: store, trigger: trigger, ready: suggestionReturn) { choose($0, replacing: trigger) }
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
      if reviewing { FloatingVoiceHost() }
      card
      if embedded == nil { footer }
    }
    .onAppear {
      draft.editorOwner = owner
      draft.recording.willUseAudio = { [weak voice = voice] in voice?.state.visible != true }
      reviewDictation()
    }
    .onChange(of: draft.dictationReview) { reviewDictation() }
    .onChange(of: scenePhase) { reviewDictation() }
    .onChange(of: voice?.state.visible) { _, calling in if calling == true { draft.recording.suspend() } }
    #if DEBUG
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
    #endif
    .onDisappear {
      if draft.editorOwner == owner { draft.editorOwner = nil }
      draft.recording.suspend()
    }
    .modifier(MacMicrophonePermission(denied: Binding(get: { draft.recording.permissionDenied }, set: { draft.recording.permissionDenied = $0 })))
    .alert("Baixar transcrição neste Mac?", isPresented: Binding(get: { draft.recording.asksDownload }, set: { draft.recording.asksDownload = $0 })) {
      Button("Baixar por Wi-Fi") { draft.recording.transcription.download(cellular: false) }
      Button("Usar qualquer rede") { draft.recording.transcription.download(cellular: true) }
      Button("Agora não", role: .cancel) {}
    } message: { Text(TranscriptionController.downloadMessage) }
    .sheet(isPresented: Binding(get: { !reviewing && draft.expanded }, set: { draft.expanded = $0 }), onDismiss: {
      draft.editorOwner = owner; draft.focused = true
    }) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Revise a mensagem").font(.headline)
          Spacer()
          Button("Concluído") { draft.expanded = false }.keyboardShortcut(.cancelAction)
        }
        MacComposer(store: store, draft: draft, embedded: embedded, reviewing: true)
      }.padding(20).frame(width: 680)
        .modifier(FloatingVoiceScope())
    }
    .sheet(item: $picking) { picker in
      MacPickerSheet(picker: picker, store: store, draft: draft)
    }
    .sheet(item: $draft.commenting) { quote in
      MacQuoteCommentSheet(quote: quote, store: store, draft: draft)
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 8) {
      if draft.attachments.contains(where: { $0.quoteID == nil }) { attachmentRow }
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
      MacComposerEditor(draft: draft, theme: theme, owner: owner, canSubmit: canSubmit, submit: submit, dictate: dictate,
        firstSuggestion: firstSuggestion, attach: { items in
          MacAttachments.receive(items, store: store, draft: draft)
        })
        .overlay(alignment: .topLeading) {
          if draft.isEmpty {
            Text(store.isChild ? "Mensagem para o subagente…" : "Pergunte qualquer coisa…").appFont(.message)
              .foregroundStyle(theme.color(.textSecondary)).allowsHitTesting(false)
          }
        }
        .padding(.horizontal, 4).padding(.top, 2)
      HStack(spacing: 8) {
        attach
        if embedded == nil {
          ComposerModelChip(label: store.modelLabel(store.selectedModel(draft)).isEmpty ? "Modelo"
            : store.modelLabel(store.selectedModel(draft))) { openModelPalette() }
            .buttonStyle(.plain).foregroundStyle(theme.color(.text))
            .help("Modelo e esforço (⌥⌘M)")
            .accessibilityIdentifier("model-picker")
          if store.mcps.summary.visible { mcp }
        }
        Spacer(minLength: 4)
        action
      }
    }
    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 18))
    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(store.isChild ? .accent : .border), lineWidth: store.isChild ? 1 : 0.7) }
  }

  private var attach: some View {
    Menu {
      Button("Arquivos…", systemImage: "doc") { MacAttachments.choose(images: false, store: store, draft: draft) }
      Button("Imagens…", systemImage: "photo") { MacAttachments.choose(images: true, store: store, draft: draft) }
      Divider()
      Button("Mencionar arquivo (!)", systemImage: "at") { insertTrigger("!") }
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

  /// `● MCP · 1/4 ⌄`: the panel of the Location's MCP servers, each switched on or off.
  private var mcp: some View {
    let summary = store.mcps.summary
    return Button {
      mcpOpen.toggle()
    } label: {
      HStack(spacing: 4) {
        Circle().fill(theme.color(summary.connected > 0 ? .success : .textWeak)).frame(width: 5, height: 5)
        Text(summary.label).monospacedDigit()
        Image(systemName: mcpOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
      }
      .appFont(.mcp).foregroundStyle(theme.color(.textSecondary))
      .composerCapsule()
    }
    .buttonStyle(.plain).fixedSize()
    .accessibilityLabel(summary.accessibilityLabel)
    .accessibilityIdentifier("conversation-mcp-pill")
    .popover(isPresented: $mcpOpen, arrowEdge: .top) { MacMCPPanel(store: store.mcps) }
  }

  @ViewBuilder private var action: some View {
    HStack(spacing: 0) {
      DictationCompactMicrophone(recording: draft.recording, hasContent: hasContent, available: dictationAvailable)
        .help("Clique ou segure para ditar · ⌃⌥Espaço no editor")
      DictationAction(recording: draft.recording, hasContent: hasContent, canSubmit: canSubmit,
        sending: draft.sending, available: dictationAvailable, submit: submit)
        .help("Segure para ditar, arraste para cima para travar · Return envia · Shift+Return quebra a linha")
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
    guard let windowRuntime, windowRuntime.app.front === windowRuntime else { return }
    if draft.recording.capturing { draft.recording.finish(); return }
    draft.recording.handle(.began); draft.recording.handle(.ended)
  }

  private func reviewDictation() {
    guard !reviewing, draft.dictationReview, scenePhase == .active, !draft.focusSuppressed else { return }
    draft.dictationReview = false
    draft.expanded = true
    draft.focused = true
  }

  /// `● build ⌄ · Contexto 28% · 278,6k / 1M · ⚡ Cache 99,5%`.
  private var footer: some View {
    // The latest measured step, else the session's own context (a session whose steps carry no tokens).
    let usage = store.sessionUsage ?? store.session?.context.flatMap {
      ContextUsage(tokens: $0.tokens, limit: store.usageLimit($0.model))
    }
    let cache = ContextUsage.cacheHit(store.session?.tokens ?? store.session?.context?.tokens)
    return HStack(spacing: 6) {
      if store.isChild || store.masterMode {
        Text(store.childAgentName).foregroundStyle(theme.color(.text))
      } else {
        Button {
          picking = .agent
        } label: {
          HStack(spacing: 4) {
            Circle().fill(agentColor).frame(width: 6, height: 6)
            Text(store.agents.first { $0.id == store.selectedAgent(draft) }?.name ?? store.selectedAgent(draft))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
          }
          .foregroundStyle(theme.color(.text))
        }
        .buttonStyle(.plain).help("Agente").accessibilityIdentifier("agent-picker")
        .disabled(draft.sending || draft.importing)
      }
      Text("·").foregroundStyle(theme.color(.textWeak))
      if let usage {
        ContextUsageRing(usage: usage, size: 10)
        Text(usage.contextLabel + " · " + usage.tokenLabel)
      } else {
        Text("Contexto —")
      }
      Text("·").foregroundStyle(theme.color(.textWeak))
      Image(systemName: "bolt.fill").font(.system(size: 9))
        .foregroundStyle(theme.color((cache ?? 1) < ContextColumn.cacheWarning ? .warning : .textSecondary))
      Text("Cache " + (cache.map(ContextColumn.percent) ?? "—"))
      Spacer(minLength: 0)
    }
    .appFont(.footnote).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
    .padding(.leading, 6)
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

  private func firstSuggestion() -> (() -> Void)? {
    guard let trigger = draft.trigger, let first = suggestionReturn.first, first.trigger == trigger else { return nil }
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
  let canSubmit: Bool
  let submit: () -> Void
  var dictate: () -> Void = {}
  let firstSuggestion: () -> (() -> Void)?
  let attach: ([NSPasteboardItem]) -> Bool

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
    text.canSubmit = canSubmit && draft.trigger == nil
    text.querying = draft.trigger != nil
    text.firstSuggestion = firstSuggestion
    text.escape = { [weak draft] in draft?.dismissSuggestions() }
    text.attach = attach
    text.insertionPointColor = theme.nsColor(.primary)
    text.isContinuousSpellCheckingEnabled = draft.trigger == nil
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

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerInputView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    let line = ceil(nsView.composerFont.ascender - nsView.composerFont.descender + nsView.composerFont.leading)
    let height = nsView.contentHeight(width: width)
    return CGSize(width: width, height: min(max(line, height), line * 8))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MacComposerEditor
    var updating = false
    init(_ parent: MacComposerEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard !updating, parent.draft.editorOwner == parent.owner,
        let input = (notification.object as? ComposerTextNSView)?.input else { return }
      parent.draft.receiveEditor(input)
      input.textView.typingAttributes = input.plainAttributes
      input.invalidateIntrinsicContentSize()
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

/// The composer inside another screen: when it may send, and how.
struct MacComposerEmbedding {
  let canSubmit: Bool
  let submit: () -> Void
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
        VStack(alignment: .leading, spacing: 2) {
          if picker == .model { models } else { agents }
        }
        .padding(8)
      }
    }
    .frame(width: 420, height: 460)
  }

  @ViewBuilder private var models: some View {
    let selected = store.selectedModel(draft)
    ForEach(store.displayModels.filter { $0.enabled != false }, id: \.identity) { info in
      let variants = info.variants ?? []
      VStack(alignment: .leading, spacing: 4) {
        row(info.name, detail: store.providerName(info.providerID),
          checked: selected?.id == info.id && selected?.providerID == info.providerID && variants.isEmpty) {
          draft.model = ModelReference(id: info.id, providerID: info.providerID)
          if variants.isEmpty { dismiss() }
        }
        if !variants.isEmpty {
          HStack(spacing: 6) {
            ForEach(variants) { variant in
              let checked = selected?.id == info.id && selected?.providerID == info.providerID
                && (selected?.variant ?? "default") == variant.id
              Button(variant.id) {
                draft.model = ModelReference(id: info.id, providerID: info.providerID, variant: variant.id)
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

/// The MCP servers of the conversation's Location, each switched on or off (the iPhone's MCP panel).
private struct MacMCPPanel: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationMCPStore
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("MCPs").appFont(.secondary, weight: .medium).foregroundStyle(theme.color(.textSecondary))
      if store.loading { ProgressView().controlSize(.small) }
      if store.failed && !store.loading {
        Button("Não foi possível carregar · Tentar novamente") { Task { await store.refresh() } }.buttonStyle(.plain)
          .appFont(.caption)
      }
      ForEach(store.chips, id: \.name) { server in
        Toggle(isOn: Binding(get: { server.status.status == .connected },
          set: { _ in Task { await store.toggle(server) } })) {
          HStack(spacing: 6) {
            Text(server.name)
            if server.status.status != .connected {
              Text(server.status.status.label).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
            }
          }
        }
        .toggleStyle(.switch).controlSize(.small)
        .disabled(server.status.status == .pending)
      }
    }
    .padding(14).frame(minWidth: 260)
    .task { await store.refresh() }
  }
}

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

  static func importFiles(_ urls: [URL], store: ConversationStore, draft: ConversationDraft) {
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
          await store.importAttachment(data, name: url.lastPathComponent, mime: mime, draft: draft)
        } catch {
          store.toast.show(error.localizedDescription, kind: .error)
        }
      }
    }
  }

  /// Pasted images (screenshots) and files.
  static func receive(_ items: [NSPasteboardItem], store: ConversationStore, draft: ConversationDraft) -> Bool {
    let files = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
    if !files.isEmpty {
      importFiles(files, store: store, draft: draft)
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
        await store.importAttachment(data, name: "Imagem-\(UUID().uuidString.prefix(6)).\(ext)",
          mime: ext == "png" ? "image/png" : "image/jpeg", draft: draft)
      }
    }
    return true
  }

  /// Files and images dropped on the conversation.
  static func receive(_ providers: [NSItemProvider], store: ConversationStore, draft: ConversationDraft) {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in importFiles([url], store: store, draft: draft) }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
          guard let data else { return }
          Task { @MainActor in
            await store.importAttachment(data, name: "Imagem-\(UUID().uuidString.prefix(6)).png", mime: "image/png",
              draft: draft)
          }
        }
      }
    }
  }
}
