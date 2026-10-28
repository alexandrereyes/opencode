import Observation
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

/// The middle column: the selected session's conversation (or the subagent opened over it) on the iPhone's
/// `ConversationStore`, so it updates live from the event stream exactly like the iPhone.
struct MacChatColumn: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: SessionStore
  @Bindable var runtime: MacWindowRuntime
  let context: ContextColumnStore?
  let titleWidth: CGFloat
  @State private var renaming = false
  @State private var renameText = ""
  @State private var deleteCandidate: Session?

  private var shownID: String? { runtime.selection.childID ?? runtime.selection.sessionID }
  private var row: SessionRow? { store.rows.first { $0.id == runtime.selection.sessionID } }

  var body: some View {
    Group {
      if let id = shownID {
        let master = runtime.selection.master && runtime.selection.childID == nil
        MacConversationView(conversation: store.conversation(id, master: master), sessions: store, runtime: runtime,
          master: master)
          .id(id)
      } else {
        VStack {
          ContentUnavailableView("Nenhuma sessão selecionada", systemImage: "bubble.left.and.bubble.right",
            description: Text("Escolha uma sessão na coluna Sessões."))
            .foregroundStyle(theme.color(.textSecondary))
          Color.clear.frame(height: 0)
            .safeAreaInset(edge: .bottom) { FloatingVoiceHost(sessions: store).padding(12) }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(theme.color(.background))
    .onChange(of: runtime.selection, initial: true) { _, selection in
      // The root and the subagent over it stay in the registry like the iPhone's navigation stack.
      runtime.app.syncShown()
      if let id = shownID { store.conversations.touch(id) }
    }
    .toolbar {
      MacPlainToolbarItem(placement: .navigation) {
        let conversation = shownID.flatMap { store.liveConversation($0) }
        MacChatTitle(
          store: store, runtime: runtime,
          title: runtime.selection.master && runtime.selection.childID == nil ? "Sessão mestra"
            : conversation?.session?.displayTitle ?? row?.session.displayTitle ?? "OpenCode",
          usage: conversation?.sessionUsage, width: titleWidth,
          running: conversation?.working ?? (row?.state == .running || shownID.map(store.active.contains) == true))
        .padding(.leading, 6)
      }
      MacToolbarFlexibleSpace()
      MacPlainToolbarItem {
        MacSessionActions(store: store, runtime: runtime).background(MacSearchAnchor(role: .actions))
      }
    }
    .onChange(of: runtime.renameRequest?.id) { _, id in
      guard id != nil, let request = runtime.renameRequest else { return }
      renameText = request.session.title ?? ""
      renaming = true
    }
    .onChange(of: runtime.deleteRequest?.id) { _, id in
      guard id != nil else { return }
      deleteCandidate = runtime.deleteRequest
      runtime.deleteRequest = nil
    }
    .alert("Renomear sessão", isPresented: $renaming) {
      TextField("Título", text: $renameText)
      Button("Cancelar", role: .cancel) { runtime.renameRequest = nil }
      Button("Salvar") {
        if let row = runtime.renameRequest { Task { await store.rename(row, title: renameText) } }
        runtime.renameRequest = nil
      }
    }
    .sessionDeleteConfirmation($deleteCandidate, store: store)
  }
}

extension Notification.Name {
  /// The chat toolbar's `+` opens the Nova sessão sheet owned by the Sessões column.
  static let macNewSession = Notification.Name("OpenCodeMacNewSession")
  /// ⌘F in the menu bar opens the open conversation's search.
  static let macSearchConversation = Notification.Name("OpenCodeMacSearchConversation")
}

/// One conversation: the subagent's way back, notices, the transcript with ↓ and the resume notice, the search
/// bar, the revert bar, the tray and the composer. Its event loop runs while it is shown.
struct MacConversationView: View {
  @Environment(\.appTheme) private var theme
  @Bindable var conversation: ConversationStore
  let sessions: SessionStore
  @Bindable var runtime: MacWindowRuntime
  /// The Sessão mestra: its own agent and title, like the iPhone's master conversation.
  var master = false
  @State private var search = ConversationSearchState()
  @State private var revertCandidate: ConversationMessage?
  @State private var commenting: ChatQuote?
  @State private var quoteDetail: ChatQuoteMark?
  @State private var quoteEditing: ChatQuote?
  @State private var quoteRevealed: String?
  @State private var quoteTask: Task<Void, Never>?
  @State private var viewing: MacViewedImage?
  @State private var dropping = false
  @State private var playerHeight: CGFloat = 0

  private var input: MacConversationInput { runtime.input(conversation) }
  private var draft: ConversationDraft { input.draft }
  private var memory: TranscriptMemory { runtime.memory(conversation.id) }
  private var transcript: MacTranscriptController? { memory.active }
  private var parentID: String? {
    conversation.session?.parentID ?? (runtime.selection.childID == conversation.id ? runtime.selection.sessionID : nil)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let parentID { childHeader(parentID) }
      if let notice = conversation.notice {
        ConversationNoticeLine(notice: notice) { Task { await conversation.refresh() } }
      }
      if let error = conversation.error {
        Button {
          Task { await conversation.refresh() }
        } label: {
          Label(error, systemImage: "arrow.clockwise").appFont(.caption).foregroundStyle(theme.color(.error))
        }
        .buttonStyle(.plain).padding(8)
      }
      if search.open { MacSearchBar(search: search, store: conversation) }
      timeline
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
    .background(theme.color(.background))
    .environment(\.conversationQuotes, quoteContext)
    .overlay {
      if dropping {
        RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(.primary), style: StrokeStyle(lineWidth: 2, dash: [6]))
          .background(theme.color(.primary).opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
          .overlay { Label("Solte para anexar", systemImage: "paperclip").appFont(.secondary, weight: .medium) }
          .padding(10).allowsHitTesting(false)
      }
    }
    .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
      MacAttachments.receive(providers, store: conversation, draft: draft)
      return true
    }
    .alert("Redefinir para este ponto?", isPresented: Binding(
      get: { revertCandidate != nil }, set: { if !$0 { revertCandidate = nil } }), presenting: revertCandidate
    ) { message in
      Button("Cancelar", role: .cancel) { revertCandidate = nil }
      Button("Redefinir", role: .destructive) {
        revertCandidate = nil
        Task { await conversation.reversion.perform(target: message, store: conversation, draft: draft) }
      }
    } message: { _ in
      Text("A mensagem volta para o campo de texto e as seguintes ficam ocultas até Refazer. Enviar uma nova mensagem apaga as ocultas de vez.")
    }
    .sheet(item: $commenting) { quote in MacQuoteCommentSheet(quote: quote, store: conversation, draft: draft) }
    .sheet(item: $quoteDetail, onDismiss: {
      if let quote = quoteEditing { quoteEditing = nil; draft.commenting = quote }
    }) { mark in
      QuoteDetailsSheet(mark: mark, edit: {
        quoteEditing = draft.quotes.first { $0.id == mark.quote.id }
        quoteDetail = nil
      }, remove: {
        quoteDetail = nil
        if mark.pending { draft.removeQuote(mark.quote); return }
        if !conversation.dismissQuotes([mark.quote.id]) {
          conversation.toast.show("A marcação foi removida, mas não pôde ser salva no Mac.", kind: .error)
        }
      }, source: {
        quoteDetail = nil
        revealQuote(mark.quote)
      }, message: {
        quoteDetail = nil
        if let id = mark.carryingMessageID {
          memory.setBubble(id, expanded: true)
          transcript?.reveal(messageID: id, animated: true)
        }
      }, close: { quoteDetail = nil })
    }
    .sheet(item: $viewing) { image in MacImageSheet(image: image) }
    .sheet(item: $conversation.sideQuestion) { launch in MacSideQuestionSheet(store: conversation, launch: launch) }
    .onChange(of: conversation.reversion.boundary(conversation.session)) { _, _ in conversation.updateActivity() }
    .onChange(of: search.query) { _, _ in
      search.cancelPaging()
      search.update(conversation, reset: true)
    }
    .onChange(of: conversation.revision) { _, _ in if search.open { search.update(conversation) } }
    .onReceive(NotificationCenter.default.publisher(for: .macSearchConversation)) { note in
      if note.object as? UUID == runtime.id { openSearch() }
    }
    .onAppear {
      runtime.app.mount(conversation)
      search.navigate = { id, offset in transcript?.reveal(messageID: id, offset: offset, animated: true) }
    }
    .task(id: conversation.session) { await conversation.presented() }
    .task(id: conversation.session?.location.directory) {
      await conversation.mcps.load(directory: conversation.session?.location.directory)
    }
    .task { await input.run() }
    .task(id: conversation.session?.location.directory) { await input.sync() }
    .onAppear { if conversation.masterMode != master { conversation.masterMode = master } }
    #if DEBUG
    .task(id: conversation.hasTranscript) {
      guard conversation.hasTranscript, MacLaunch.fixture, let mode = MacDetailsFixture.mode else { return }
      await draft.load()
      draft.text = NSAttributedString(string: "")
      draft.quotes = mode == "quotes" || mode == "details" ? MacDetailsFixture.quotes : []
      if mode == "bubble" { memory.setBubble("msg_details_prompt", expanded: true) }
      if mode == "shell" {
        for row in conversation.activity.messages.flatMap(\.rows) where row.kind == .group {
          conversation.expansionValues[row.id] = true
          for part in row.parts { conversation.expansionValues["activity:detail:" + part.id] = true }
        }
      }
      try? await Task.sleep(for: .seconds(2))
      transcript?.reveal(messageID: "msg_details_prompt")
    }
    .onChange(of: conversation.hasTranscript, initial: true) { _, loaded in
      // Captures can show the first activity card open (`-OpenCodeMacOpenActivity`), like the approved mock.
      guard loaded, ProcessInfo.processInfo.arguments.contains("-OpenCodeMacOpenActivity"),
        let first = conversation.activity.messages.flatMap(\.rows).first(where: { $0.kind == .group }),
        conversation.expansionValues[first.id] == nil else { return }
      conversation.expansionValues[first.id] = true
    }
    .task {
      // `-OpenCodeMacLiveTrace`: once a second, what this conversation shows, to verify it updates live.
      guard ProcessInfo.processInfo.arguments.contains("-OpenCodeMacLiveTrace") else { return }
      while !Task.isCancelled {
        let last = conversation.messages.last
        macTrace("live \(conversation.id) revision=\(conversation.revision) messages=\(conversation.messages.count) "
          + "last=\(last?.id ?? "-") text=\(last?.responseText.count ?? 0) tools=\(last?.tools.count ?? 0) "
          + "executing=\(conversation.executing) items=\(transcript?.items.count ?? 0)")
        try? await Task.sleep(for: .seconds(1))
      }
    }
    #endif
    .onDisappear {
      quoteTask?.cancel()
      runtime.app.unmount(conversation)
      input.readAloud.stop()
      draft.recording.suspend()
      search.cancelPaging()
      transcript?.capture()
      Task { await draft.persist() }
    }
  }

  /// A subagent shows where it came from and goes back with ‹ or ⌘[, like the iPhone's back button.
  private func childHeader(_ parent: String) -> some View {
    let parentTitle = sessions.liveConversation(parent)?.session?.displayTitle
      ?? sessions.entries.first { $0.session.id == parent }?.session.displayTitle ?? "Sessão principal"
    return MacSubagentBanner(conversation: conversation, parentTitle: parentTitle) {
      transcript?.capture()
      runtime.backToParent()
    }
  }

  private var timeline: some View {
    MacTranscriptHost(
      store: conversation, sessions: sessions, memory: memory, reading: runtime.reading,
      quotes: quoteContext,
      search: ConversationSearchHighlight(matches: search.matches, current: search.current?.id),
      bottomPadding: playerHeight > 0 ? playerHeight + 24 : 16
    ) { context in
      context.openChild = { id in open(child: id) }
      context.openPath = { path in openFile(path) }
      context.revert = { message in revertCandidate = message }
      context.comment = { quote in commenting = quote }
      context.openImage = { image, name in viewing = MacViewedImage(image: image, name: name) }
      context.readAloud = { id in
        guard let response = ReadAloud.response(conversation.messages, endingAt: id, sessionID: conversation.id),
          !response.text.isEmpty else { return }
        input.readAloud.read(response, title: conversation.session?.displayTitle ?? "Resposta", client: sessions.client)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      ConversationBottomControls(readAloud: input.readAloud, state: memory.state,
        jump: { transcript?.scrollToLatest(animated: true) },
        reveal: { transcript?.reveal(messageID: $0, animated: true) }, height: { playerHeight = $0 })
        .frame(maxWidth: 760)
    }
    .overlay(alignment: .top) {
      if memory.state.resumeOffered {
        Button("Continuar de onde parou") { transcript?.resume() }
          .buttonStyle(.plain).appFont(.caption, weight: .medium)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .adaptiveGlass(Capsule())
          .padding(.top, CGFloat(memory.state.stickyHeight) + 8)
      }
    }
    .overlay {
      if !conversation.hasTranscript && conversation.error == nil {
        ProgressView("Carregando conversa…").appFont(.caption)
      }
    }
  }

  private var quoteContext: ConversationQuoteContext {
    ConversationQuoteContext(index: conversation.quoteIndex, pending: draft.quotes,
      dismissed: conversation.dismissedQuotes, revealing: quoteRevealed,
      open: { quoteDetail = $0 }, source: revealQuote, active: quoteDetail?.id)
  }

  private func revealQuote(_ quote: ChatQuote) {
    quoteTask?.cancel()
    quoteRevealed = conversation.quoteIndex.marks(messageID: quote.messageID, partID: quote.partID)
      .first { $0.quote.id == quote.id }?.id ?? ChatQuoteMark(quote: quote, number: 1).id
    quoteTask = Task { @MainActor in
      guard await transcript?.revealQuote(quote) == true else {
        quoteRevealed = nil
        return
      }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      quoteRevealed = nil
    }
  }

  private var bottom: some View {
    VStack(spacing: 8) {
      FloatingVoiceHost(sessions: sessions)
      if conversation.session?.revert != nil, !conversation.isChild { revertBar }
      ConversationTray(store: conversation, draft: draft)
      MacComposer(store: conversation, draft: draft)
        .disabled(!conversation.ready || conversation.notice != nil)
    }
    .frame(maxWidth: 760)
    .padding(.horizontal, 24).padding(.bottom, 10).padding(.top, 6)
    .frame(maxWidth: .infinity)
  }

  private var revertBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "arrow.uturn.backward").foregroundStyle(theme.color(.icon))
      Text("Mensagens seguintes ocultas").foregroundStyle(theme.color(.textSecondary))
      Spacer()
      Button("Refazer") { Task { await conversation.reversion.perform(target: nil, store: conversation, draft: draft) } }
        .buttonStyle(.plain).foregroundStyle(theme.color(.primary))
        .disabled(conversation.reversion.pending)
    }
    .appFont(.footnote)
    .padding(.horizontal, 14).padding(.vertical, 8)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.border), lineWidth: 0.7) }
  }

  private func openSearch() {
    transcript?.capture()
    search.open = true
  }

  /// A subagent opens in the middle column over its root, which Sessões keeps selected.
  private func open(child id: String) {
    transcript?.capture()
    runtime.selection.childID = id
  }

  /// A file named in an answer opens Arquivos at its folder, with the file selected.
  private func openFile(_ source: String) {
    guard let directory = conversation.session?.location.directory else { return }
    Task {
      let path = try? await sessions.client.fileLinkMatches(source, directory: directory).first
      guard let path else {
        conversation.toast.show("Arquivo não encontrado: \(source)", kind: .error)
        return
      }
      runtime.showFiles(at: URL(fileURLWithPath: path).deletingLastPathComponent().path, file: path)
    }
  }
}

/// A notice above the transcript (a vanished directory, an older server), with a retry.
private struct ConversationNoticeLine: View {
  @Environment(\.appTheme) private var theme
  let notice: ConversationNotice
  let retry: () -> Void
  private var message: String {
    switch notice {
    case .incompatible: "Este servidor é antigo demais para esta conversa. Atualize o OpenCode no servidor."
    case .missingDirectory(let path): "O diretório da sessão não existe mais: \(path). Envio indisponível."
    }
  }
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.color(.warning))
      Text(message).foregroundStyle(theme.color(.text))
      Spacer()
      Button("Tentar novamente", action: retry).buttonStyle(.plain).foregroundStyle(theme.color(.primary))
    }
    .appFont(.caption).padding(.horizontal, 24).padding(.vertical, 8)
    .background(theme.color(.surface))
  }
}

/// ⌘F: the conversation's search with its counter, ↑/↓ (or Return / Shift-Return) and older pages.
private struct MacSearchBar: View {
  @Environment(\.appTheme) private var theme
  @Bindable var search: ConversationSearchState
  let store: ConversationStore
  @FocusState private var focused: Bool
  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textSecondary))
        TextField("Buscar na conversa", text: $search.query)
          .textFieldStyle(.plain).focused($focused)
          .onSubmit { search.move(NSEvent.modifierFlags.contains(.shift) ? -1 : 1, store: store) }
          .accessibilityIdentifier("conversation-search")
        Text(ConversationSearch.counter(index: search.index, count: search.matches.count))
          .monospacedDigit().foregroundStyle(theme.color(.textSecondary))
        Button { search.move(-1, store: store) } label: { Image(systemName: "chevron.up") }
          .buttonStyle(.plain).disabled(search.matches.isEmpty).help("Resultado anterior")
        Button { search.move(1, store: store) } label: { Image(systemName: "chevron.down") }
          .buttonStyle(.plain).disabled(search.matches.isEmpty).help("Próximo resultado")
        Button("Concluído") { search.close() }.buttonStyle(.plain).foregroundStyle(theme.color(.primary))
          .keyboardShortcut(.cancelAction)
      }
      if store.hasOlder && (search.index == nil || search.index == 0 || search.paging) {
        HStack(spacing: 8) {
          if search.paging {
            ProgressView().controlSize(.small)
            Text("Buscando mensagens anteriores…")
            Button("Cancelar") { search.cancelPaging() }.buttonStyle(.plain)
          } else {
            Button("Buscar em mensagens mais antigas") { search.older(store) }.buttonStyle(.plain)
              .disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      }
    }
    .appFont(.secondary)
    .padding(.horizontal, 24).padding(.vertical, 8)
    .background(theme.color(.surface))
    .overlay(alignment: .bottom) { ContextHairline() }
    .onAppear { focused = true }
  }
}

struct MacViewedImage: Identifiable {
  let id = UUID()
  let image: CGImage
  let name: String
}

/// An image from the conversation at full size.
private struct MacImageSheet: View {
  @Environment(\.dismiss) private var dismiss
  let image: MacViewedImage
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(image.name).lineLimit(1)
        Spacer()
        Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(12)
      ScrollView([.horizontal, .vertical]) {
        Image(decorative: image.image, scale: 2)
      }
    }
    .frame(minWidth: 520, idealWidth: min(CGFloat(image.image.width) / 2 + 40, 1100), minHeight: 400,
      idealHeight: min(CGFloat(image.image.height) / 2 + 80, 800))
  }
}

/// Comentar: a quote of the selected passage with its comment, attached to the next prompt (`Citações · N`).
struct MacQuoteCommentSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let quote: ChatQuote
  let store: ConversationStore
  let draft: ConversationDraft
  @State private var editor: ConversationDraft
  @State private var lent = false
  @State private var committed = false
  init(quote: ChatQuote, store: ConversationStore, draft: ConversationDraft) {
    self.quote = quote
    self.store = store
    self.draft = draft
    _editor = State(initialValue: draft.commentEditor(quote))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Comentar trecho").appFont(.heading, weight: .semibold)
      Text(quote.text).appFont(.secondary).lineLimit(6).foregroundStyle(theme.color(.textSecondary))
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(theme.color(.primary)).frame(width: 2) }
      MacComposer(store: store, draft: editor, embedded: MacComposerEmbedding(canSubmit: lent && !editor.importing, submit: commit))
      HStack {
        Spacer()
        Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Concluir", action: commit).disabled(!lent || editor.importing)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20).frame(width: 480)
    .task {
      guard !lent else { return }
      await draft.lend(quote, to: editor)
      lent = true
      editor.focused = true
    }
    .onDisappear { if !committed { Task { try? await editor.discard() } } }
  }
  private func commit() {
    guard lent, !editor.importing, !committed else { return }
    committed = true
    Task {
      await draft.commit(quote, from: editor)
      try? await editor.discard()
      draft.focused = true
    }
    dismiss()
  }
}

/// `/btw`: a side question about the conversation, answered without saving it there.
private struct MacSideQuestionSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  let launch: SideQuestionLaunch
  @State private var question = ""
  @State private var entries: [SideQuestionEntry] = []
  @State private var asking = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Pergunta paralela").appFont(.heading, weight: .semibold)
        Spacer()
        Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("Não fica salva na conversa.").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(entries) { entry in
            Text(entry.question).appFont(.secondary, weight: .medium)
            Text((try? AttributedString(markdown: entry.answer,
              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(entry.answer))
              .textSelection(.enabled)
          }
          if asking { ProgressView().controlSize(.small) }
          if let error { Text(error).foregroundStyle(theme.color(.error)).appFont(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        TextField("Pergunte algo sem interromper a conversa…", text: $question).textFieldStyle(.roundedBorder)
          .onSubmit(ask)
        Button("Perguntar", action: ask).disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20).frame(width: 560, height: 480)
    .onAppear {
      question = launch.text
      if launch.submit { ask() }
    }
  }

  private func ask() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !asking else { return }
    asking = true
    error = nil
    question = ""
    Task {
      defer { asking = false }
      do {
        let answer = try await store.askSideQuestion(SideQuestionRequest(question: text, history: entries))
        entries.append(SideQuestionEntry(question: text, answer: answer))
      } catch {
        self.error = "Não foi possível responder. \(error.localizedDescription)"
        question = text
      }
    }
  }
}
