import OpenCodeKit
import SwiftUI

struct ConversationView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.voiceController) private var voice
  @Environment(\.floatingVoice) private var floatingVoice
  @State private var conversation: ConversationStore
  @State private var contextOpen = false
  @State private var detailsOpen = false
  @State private var switcherOpen = false
  /// Applied once the sheet has dismissed, so the current conversation saves its place first.
  @State private var switcherChoice: SwitcherChoice?
  private enum SwitcherChoice {
    case session(String)
    case create(SessionListFilter)
  }
  @State private var renameOpen = false
  @State private var renameTitle = ""
  @State private var archiveOpen = false
  @State private var deleteCandidate: Session?
  @State private var search = ConversationSearchState()
  @State private var requestedTool: String?
  /// Opened from a question or permission alert: the pending requests sit at the end of the transcript.
  @State private var requestedEnd: Bool
  /// Unknown until measured; a retained transcript keeps the last known size meanwhile.
  @State private var size: CGSize?
  @State private var note: TranscriptNote?
  @State private var screenVisible = true
  @State private var quoteDetail: ChatQuoteMark?
  @State private var quoteTarget: ChatQuoteMark?
  @State private var quoteAligned: String?
  @State private var quoteEditing: ChatQuote?
  @State private var quoteValidation: Task<Void, Never>?
  @State private var quoteRevealed: String?
  @State private var quoteMessage: String?
  @State private var quoteRevealTask: Task<Void, Never>?
  @State private var revertCandidate: ConversationMessage?
  @State private var readAloudHeight: CGFloat = 0
  /// A subagent's path sheet (its badge), and the level chosen there, applied once the sheet has dismissed.
  @State private var pathOpen = false
  @State private var pathChoice: String?
  let sessions: SessionStore
  let master: Bool

  init(
    id: String, sessions: SessionStore, toolID: String? = nil, master: Bool = false, atRequest: Bool = false
  ) {
    self.sessions = sessions
    self.master = master
    _requestedTool = State(initialValue: toolID)
    _requestedEnd = State(initialValue: atRequest)
    _conversation = State(initialValue: sessions.conversation(id, master: master))
  }
  /// The mounted transcript that scrolls for this screen.
  private var transcript: TranscriptViewController? { conversation.memory.active }
  private var chat: Bool {
    if master { return true }
    guard let directory = conversation.session?.location.directory, let root = sessions.chatRoot else { return false }
    return directory == root || directory.hasPrefix(root + "/")
  }
  private var showLocation: Bool { sessions.chatRoot != nil && !chat }
  /// A vanished directory of a Git project (never a chat) can move to the project's root checkout.
  private var relocationProject: Project? {
    guard case .missingDirectory(let missing) = conversation.notice, sessions.chatRoot != nil, !chat,
      let project = sessions.projects.first(where: { $0.id == conversation.session?.projectID }),
      SessionRelocation.root(project, missing: missing) != nil
    else { return nil }
    return project
  }
  private var relocationKey: String? { relocationProject.map { $0.id + "\n" + (conversation.session?.location.directory ?? "") } }
  private var relocation: ConversationRelocation? {
    guard let project = relocationProject else { return nil }
    return ConversationRelocation(
      root: project.canonical, worktrees: conversation.relocationWorktrees,
      children: conversation.strandedChildren.count, running: conversation.executing,
      moving: conversation.relocating
    ) { directory, children in
      Task { await conversation.relocate(to: directory, children: children) }
    }
  }
  private var headerSubtitle: String {
    if chat { return conversation.modelLabel(conversation.session?.model) }
    // Do not expose a directory fallback before the managed-chat root has been resolved.
    return conversation.located?.branch ?? (showLocation ? conversation.branch : "")
  }
  private var headerStatus: String {
    conversation.waiting ? "aguardando você" : conversation.working ? "trabalhando…" : ""
  }
  var body: some View {
    VStack(spacing: 0) {
      header
      if let notice = conversation.notice {
        ConversationNoticeView(notice: notice, showDirectory: showLocation, relocation: relocation) {
          Task { await conversation.refresh() }
        }
        .task(id: relocationKey) {
          if let project = relocationProject { await conversation.loadRelocation(project) }
        }
      }
      if let error = conversation.error {
        Button {
          Task { await conversation.refresh() }
        } label: {
          Label(error, systemImage: "arrow.clockwise").appFont(.caption).foregroundStyle(
            theme.color(.error)
          ).padding(10)
        }
      }
      timeline.toastOverlay(conversation.toast)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { conversation.mcps.transcriptFrame = $0 }
        .highPriorityGesture(TapGesture().onEnded { conversation.mcps.close() },
          including: conversation.mcps.isOpen ? .all : .none)
        .simultaneousGesture(
          TapGesture().onEnded {
            sessions.drafts.draft(conversation.id).dismissSuggestions()
            sessions.drafts.draft(conversation.id).focused = false
          }, including: conversation.mcps.isOpen ? .none : .all)
      if floatingVoice?.visible(voice) == true {
        FloatingVoiceHost(sessions: sessions).padding(.horizontal, 12).padding(.top, 8)
      }
      bottomArea
    }
    .background(theme.color(.background))
    // The bottom stack owns the home-indicator band; keyboard avoidance remains native.
    .ignoresSafeArea(.container, edges: .bottom)
    .modifier(ConversationMCPOverlay(store: conversation.mcps))
    .modifier(FileViewerHost())
    .environment(conversation.toast)
    .environment(\.transcriptMemory, conversation.memory)
    .environment(\.conversationQuotes, ConversationQuoteContext(
      index: conversation.quoteIndex, pending: sessions.drafts.draft(conversation.id).quotes,
      dismissed: conversation.dismissedQuotes, revealing: quoteRevealed, revealedMessage: quoteMessage,
      open: { quoteDetail = $0 }, source: { revealQuote($0) }, target: quoteTarget?.id, active: quoteDetail?.id,
      align: { id, message, offset in
        guard quoteTarget?.id == id, quoteAligned != id else { return }
        quoteAligned = id
        quoteTarget = nil
        conversation.revealMessage(message, offset: max(0, offset - 24), persist: false)
        // A dismissed mark is drawn only long enough to show where the source passage is.
        quoteRevealTask?.cancel()
        quoteRevealTask = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(3)) } catch { return }
          if quoteRevealed == id { quoteRevealed = nil }
        }
      }))
    .environment(\.userMessageRevert, conversation.isChild ? nil : UserMessageRevertAction(
      pending: sessions.drafts.draft(conversation.id).sending
        || sessions.drafts.draft(conversation.id).importing,
      revert: { id in
        revertCandidate = conversation.messages.first { $0.id == id && $0.type == "user" }
      }))
    .environment(\.snippetEditorContext, SnippetEditorContext(
      catalog: sessions.snippets, projects: sessions.projects, project: conversation.session?.projectID))
    .revertConfirmation($revertCandidate) { message in
      Task {
        await conversation.reversion.perform(target: message, store: conversation,
          draft: sessions.drafts.draft(conversation.id))
      }
    }
    // Only pinned prompts read this size; it changes on every frame of a keyboard transition.
    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    .environment(\.conversationImages, conversation.session.map {
      ConversationImageContext(client: sessions.client, directory: $0.location.directory, sessionID: $0.id)
    })
    .environment(\.conversationSearch, ConversationSearchHighlight(matches: search.matches, current: search.current?.id, align: {
      search.align($0, offset: $1, store: conversation)
    }))
    // Selecting text no longer pauses anything: growth never scrolls the transcript.
    .environment(\.responseSelectionChanged, ResponseSelectionObserver(selected: {}))
    .environment(
      \.responseSelection,
      ResponseSelectionActions(
        comment: { quote in
          let draft = sessions.drafts.draft(conversation.id)
          draft.focused = false
          draft.commenting = quote
        },
        sideQuestion: { text in
          sessions.drafts.draft(conversation.id).focused = false
          conversation.sideQuestion = SideQuestionLaunch(text: SideQuestionRequest.quote(text))
        })
    )
    .background(ConversationBackGesture(capture: leavePosition, appeared: { screenVisible = true }))
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: conversation.reversion.boundary(conversation.session)) { _, _ in
      conversation.updateActivity()
    }
    .onChange(of: conversation.toolRequest, initial: true) { _, tool in
      guard let tool else { return }
      conversation.toolRequest = nil
      conversation.revealedToolID = tool
      requestedTool = tool
    }
    .sheet(isPresented: $pathOpen, onDismiss: {
      guard let id = pathChoice else { return }
      pathChoice = nil
      openLevel(id)
    }) {
      if let subagent = subagentHeader {
        SubagentPathSheet(levels: subagent.levels, current: conversation.id, sessions: sessions) { id in
          pathChoice = id
          pathOpen = false
        } close: {
          pathOpen = false
        }
        .sessionAlertOverlay()
      }
    }
    .sheet(isPresented: $contextOpen) { ConversationContextSheet(store: conversation, showLocation: showLocation).sessionAlertOverlay() }
    .sheet(item: $quoteDetail, onDismiss: {
      if let quote = quoteEditing {
        quoteEditing = nil
        sessions.drafts.draft(conversation.id).commenting = quote
      }
    }) { mark in
      QuoteDetailsSheet(mark: mark, edit: {
        quoteDetail = nil
        let draft = sessions.drafts.draft(conversation.id)
        draft.focused = false
        quoteEditing = draft.quotes.first { $0.id == mark.quote.id }
      }, remove: {
        quoteDetail = nil
        guard !mark.pending else {
          sessions.drafts.draft(conversation.id).removeQuote(mark.quote)
          return
        }
        if !conversation.dismissQuotes([mark.quote.id]) {
          conversation.toast.show("A marcação foi removida, mas não pôde ser salva no iPhone.", kind: .error)
        }
      }, source: {
        quoteDetail = nil
        revealQuote(mark.quote, mark: mark)
      }, message: {
        quoteDetail = nil
        if let id = mark.carryingMessageID {
          quoteMessage = id
          conversation.revealMessage(id, persist: false)
        }
      }, close: { quoteDetail = nil })
    }
    .sheet(
      isPresented: $switcherOpen,
      onDismiss: {
        guard let choice = switcherChoice else { return }
        switcherChoice = nil
        switch choice {
        case .session(let id): switchSession(to: id)
        case .create(let filter):
          leavePosition()
          sessions.conversationPath.append(.init(id: "draft_" + UUID().uuidString,
            newSession: true, startInChats: true, startFilter: filter))
        }
      }
    ) {
      SessionSwitcherSheet(sessions: sessions, current: conversation.id) { id in
        switcherChoice = .session(id)
        switcherOpen = false
      } newSession: { filter in
        switcherChoice = .create(filter)
        switcherOpen = false
      }
      .sessionAlertOverlay()
    }
    .sheet(isPresented: $detailsOpen) {
      SessionDetailsSheet(store: conversation, project: sessions.projects.first { $0.id == conversation.session?.projectID }, isChat: chat, showLocation: showLocation) {
        contextOpen = true
      }.sessionAlertOverlay()
        .environment(\.conversationImages, conversation.session.map {
          ConversationImageContext(client: sessions.client, directory: $0.location.directory, sessionID: $0.id)
        })
    }
    .background(ConversationRenameAlert(isPresented: $renameOpen, title: renameTitle, theme: theme) { title in
      Task { await conversation.rename(title) }
    }.frame(width: 0, height: 0))
    .confirmationDialog("Arquivar sessão?", isPresented: $archiveOpen, titleVisibility: .visible) {
      Button("Arquivar", role: .destructive) {
        Task {
          if await conversation.archive() {
            sessions.toast.show("Sessão arquivada")
            leavePosition()
            sessions.conversations.removeFamily(conversation.id, sessions: sessions.entries.map(\.session))
            dismiss()
            await sessions.reload()
          }
        }
      }
      Button("Cancelar", role: .cancel) {}
    } message: {
      Text("A sessão sairá de Recentes e ficará na lista de arquivadas. Não há opção de desarquivar nesta versão.")
    }
    .sessionDeleteConfirmation($deleteCandidate, store: sessions)
    .onChange(of: search.query) { _, _ in
      search.cancelPaging()
      search.update(conversation, reset: true)
    }
    .onChange(of: conversation.revision) { _, _ in
      if search.open { search.update(conversation) }
    }
    .onChange(of: conversation.memory.state.restoring) { old, value in
      guard old, !value, !conversation.memory.state.resumeOffered, screenVisible else { return }
      validateQuoteTarget()
    }
    // One event loop while the screen is shown. Hiding the app does not restart it: the reconnection that
    // follows merges the tail without republishing an unchanged transcript.
    .task { await conversation.run() }
    .task(id: conversation.session) {
      if screenVisible { await conversation.presented() }
    }
    .task(id: conversation.session?.location.directory) {
      await conversation.mcps.load(directory: conversation.session?.location.directory)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
      conversation.mcps.close()
    }
    .onChange(of: sessions.drafts.draft(conversation.id).expanded) { _, _ in conversation.mcps.close() }
    .background(DraftTriggerObserver(draft: sessions.drafts.draft(conversation.id)) { conversation.mcps.close() })
    .task(id: conversation.revision) { await ResponseMarkdownCache.shared.prepare(conversation.messages) }
    .onAppear {
      sessions.conversations.touch(conversation.id)
      if conversation.masterMode != master { conversation.masterMode = master }
      screenVisible = true
    }
    .onDisappear {
      // Leaving the conversation ends its reading, saving the place.
      conversation.readAloud.stop()
      quoteValidation?.cancel()
      quoteRevealTask?.cancel()
      quoteRevealed = nil
      conversation.mcps.close()
      search.cancelPaging()
      leavePosition()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { conversation.revalidate() }
      if phase != .active {
        // The exact passage stays; anything arriving meanwhile lands outside it.
        if screenVisible { transcript?.capture() }
        Task { await sessions.drafts.draft(conversation.id).persist() }
      }
    }
  }
  private var bottomArea: some View {
    Group {
      if search.open {
        ConversationSearchBar(search: search, store: conversation)
      } else if conversation.notice != nil {
        Text("Envio indisponível até resolver o aviso acima.").appFont(.caption)
          .foregroundStyle(theme.color(.textSecondary)).padding(14).frame(maxWidth: .infinity)
      } else {
        VStack(spacing: 0) {
          if let progress = conversation.progress(fallback: sessions.progress(conversation.id)) {
            ConversationProgressPill(progress: progress).padding(.bottom, 8)
          }
          ConversationTray(store: conversation, draft: sessions.drafts.draft(conversation.id))
            .padding(.bottom, 8)
          ConversationComposer(store: conversation, draft: sessions.drafts.draft(conversation.id), footer: false)
            .anchorPreference(key: MCPComposerAnchorKey.self, value: .bounds) { $0 }
            .disabled(!conversation.ready)
          if !sessions.drafts.draft(conversation.id).expanded {
            ComposerFooter(store: conversation, draft: sessions.drafts.draft(conversation.id),
              usage: conversation.sessionUsage) { detailsOpen = true }
          } else {
            Color.clear.frame(height: 40).accessibilityHidden(true)
          }
        }
        .padding(.horizontal, AppLayout.composerMargin).padding(.top, 8).padding(.bottom, 0).background(
          theme.color(.background))
      }
    }
  }
  private var header: some View {
    Group {
      if search.open {
        HStack(spacing: 12) {
          ConversationSearchField(text: $search.query, theme: theme) {
            search.move(1, store: conversation)
          }.frame(height: 44)
          Button("Cancelar") {
            search.close()
          }
          .accessibilityIdentifier("conversation-search-close")
        }.padding(.horizontal, 16).padding(.vertical, 8)
      } else { normalHeader }
    }.background(theme.color(.background))
  }
  private var normalHeader: some View {
    // Both projections walk the transcript; the header reads each several times per update.
    let context = conversation.context
    let running = conversation.runningCount
    let subagent = subagentHeader
    return HStack(spacing: 9) {
      backButton(subagent)
      // Root conversations switch sessions from the avatar and title; the master and children keep the avatar's
      // Detalhes da sessão (also in the … menu or a subagent's long press, and in the context footer).
      let switches = !master && conversation.session.map { $0.parentID == nil } == true
      HStack(spacing: 9) {
      if let session = conversation.session {
        let project = sessions.projects.first { $0.id == session.projectID }
        let colors = theme.avatar(SessionList.avatarColor(project, fallback: session.projectID))
        let monogram = SessionList.monogram(chat || project?.vcs == nil ? session.displayTitle : project?.displayName ?? session.displayTitle)
        Button {
          detailsOpen = true
        } label: {
          ConversationAvatar(
            context: context, master: master, colors: colors, monogram: monogram,
            icon: master || chat || subagent != nil ? nil : ProjectIcon.of(project),
            agent: subagent == nil ? nil : theme.color(.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          context.map { "Contexto: \(Int(($0 * 100).rounded()))%" }
            ?? "Contexto desconhecido")
        .accessibilityIdentifier("conversation-header-avatar")
        .accessibilityValue(master ? "Sessão mestra" : monogram)
      }
      let title = ConversationTitle(
        title: master ? "Sessão mestra" : conversation.session?.displayTitle ?? "Conversa", switches: switches,
        subtitle: subagent?.subtitle ?? headerSubtitle, status: headerStatus, waiting: conversation.waiting,
        kicker: subagent?.kicker)
      if subagent != nil {
        // A subagent's badge, title and parent open its path; a long press has the … menu's actions that make sense
        // there (a subagent has no … button: the agents capsule takes its place). The avatar keeps Detalhes.
        title.overlay {
          SubagentBadgeButton(theme: theme, actions: .init(path: {
            sessions.drafts.draft(conversation.id).focused = false
            pathOpen = true
          }, search: openSearch, rename: openRename, details: { detailsOpen = true }))
        }
      } else {
        title
      }
      }
      // A clear button over the avatar and title keeps their readouts while VoiceOver also gets the action.
      .overlay {
        if switches {
          Button {
            sessions.drafts.draft(conversation.id).focused = false
            switcherOpen = true
          } label: {
            Color.clear.contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Trocar de sessão")
          .accessibilityIdentifier("conversation-switcher")
        }
      }
      if !conversation.work.isEmpty || !conversation.resources.isEmpty {
        let resources = conversation.resources.filter(\.state.running).count
        Button {
          leavePosition()
          sessions.conversationPath.append(.init(id: conversation.id, agents: true))
        } label: {
          HStack(spacing: 6) {
            AgentPixels(color: theme.color(running > 0 ? .success : .textSecondary), size: 16, running: running > 0)
            if running > 0 { Text("\(running)").appFont(.secondary).monospacedDigit() }
            if !conversation.resources.isEmpty {
              Rectangle().fill(theme.color(.border)).frame(width: 1, height: 16)
              Image(systemName: "macbook.and.iphone").appSymbol(.inline)
                .foregroundStyle(theme.color(resources > 0 ? .textStrong : .textSecondary))
              if resources > 0 { Text("\(resources)").appFont(.secondary).monospacedDigit() }
            }
          }
          .padding(.horizontal, 9).frame(minWidth: 36).frame(height: 36).glassEffect(
            .regular.interactive(), in: .capsule)
        }.buttonStyle(.plain).accessibilityLabel(
          ConversationAgentsView.runningLabel(agents: conversation.runningAgents, scripts: running - conversation.runningAgents)
            + (conversation.resources.isEmpty ? "" : resources == 1 ? ", 1 recurso ativo" : ", \(resources) recursos ativos"))
          .accessibilityIdentifier("conversation-agents")
      }
      if master {
        Button {
          sessions.drafts.draft(conversation.id).focused = false
          Task { await sessions.resetMaster() }
        } label: {
          Image(systemName: "trash").frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: .circle)
        }.accessibilityLabel("Reiniciar Sessão mestra").accessibilityIdentifier("master-trash")
          .disabled(sessions.busy.contains("master-reset"))
      } else if subagent == nil {
      ConversationOptionsMenu(
        sessionID: conversation.id, available: conversation.session != nil,
        canArchive: conversation.session?.parentID == nil, archiving: conversation.acting.contains("archive"),
        deleting: sessions.busy.contains(conversation.id),
        theme: theme,
        actions: .init(search: openSearch, rename: openRename, details: {
          #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("-OpenCodeMenuDiagnostics") {
            NSLog("DETAILS action session=%@ child=%@", conversation.id, String(conversation.isChild))
          }
          #endif
          detailsOpen = true
        }, archive: { archiveOpen = true }, delete: conversation.id == sessions.masterID ? nil : {
          sessions.drafts.draft(conversation.id).focused = false
          Haptics.play(.warning)
          deleteCandidate = conversation.session
        }, newSession: startNewSession))
        .frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: .circle)
      }
    }
    .foregroundStyle(theme.color(.textStrong)).padding(.horizontal, AppLayout.margin).padding(.vertical, 6)
    .background {
      // A subagent's header, like the Mac's banner: a faint accent tint and an accent stripe at the leading edge.
      if subagent != nil {
        ZStack(alignment: .leading) {
          theme.color(.background)
          theme.color(.accent).opacity(0.08)
          Rectangle().fill(theme.color(.accent)).frame(width: 3)
        }
      } else {
        theme.color(.background)
      }
    }
  }
  /// What a subagent's header shows: `SUBAGENTE · NÍVEL 2 · ASTRAMAX`, `de <parent>` and the levels from the
  /// top-level session down to it. Nil for a top-level session and the master.
  private var subagentHeader: SubagentHeader? {
    guard !master, let session = conversation.session, let parent = session.parentID else { return nil }
    let ancestors = conversation.ancestors
    let root = ancestors.first ?? sessions.entries.first { $0.session.id == parent }?.session
    // From the loaded sessions (the list, the root's family, the ancestors this conversation read).
    let below = root.map { sessions.subagentPath(root: $0.id, child: conversation.id) } ?? []
    let levels = (root.map { [$0] } ?? []) + (below.isEmpty ? [session] : below)
    let depth = max(1, levels.count - 1)
    let parentTitle = levels.dropLast().last?.displayTitle
      ?? sessions.liveConversation(parent)?.session?.displayTitle
    return SubagentHeader(
      kicker: (["SUBAGENTE"] + (depth > 1 ? ["NÍVEL \(depth)"] : []) + [conversation.childAgentName.uppercased()])
        .joined(separator: " · "),
      subtitle: parentTitle.map { "de " + $0 } ?? "",
      levels: levels)
  }
  /// Back returns to where Alexandre came from (the list of agents or the parent); a subagent's long press lists
  /// every level up to the top-level session.
  @ViewBuilder private func backButton(_ subagent: SubagentHeader?) -> some View {
    let label = Image(systemName: "chevron.left").appSymbol(.navigation).frame(width: 36, height: 36)
      .glassEffect(.regular.interactive(), in: .circle)
    if let subagent {
      Menu {
        ForEach(Array(subagent.levels.enumerated()), id: \.element.id) { index, level in
          Button {
            openLevel(level.id)
          } label: {
            Text(level.displayTitle)
            Text(index == 0 ? "sessão principal" : level.id == conversation.id ? "você está aqui" : "subagente")
          }
          .disabled(level.id == conversation.id)
          .accessibilityIdentifier("subagent-level-" + level.id)
        }
      } label: {
        label
      } primaryAction: {
        leavePosition()
        dismiss()
      }
      .buttonStyle(.plain).accessibilityLabel("Voltar").accessibilityHint("Toque longo para os níveis")
      .accessibilityIdentifier("conversation-back")
    } else {
      Button {
        leavePosition()
        dismiss()
      } label: {
        label
      }
      .buttonStyle(.plain).accessibilityLabel("Voltar")
    }
  }
  /// A level of the path: back down the stack when it is there (past its agents screen), else opened on top, so
  /// Back still returns here.
  private func openLevel(_ id: String) {
    guard id != conversation.id else { return }
    leavePosition()
    if let index = sessions.conversationPath.lastIndex(where: {
      $0.id == id && !$0.agents && !$0.newSession && !$0.master
    }) {
      sessions.conversationPath.removeSubrange((index + 1)...)
      return
    }
    sessions.conversationPath.append(.init(id: id, parent: conversation.id))
  }
  private func openSearch() {
    sessions.drafts.draft(conversation.id).focused = false
    transcript?.capture()
    search.open = true
  }
  private func openRename() {
    renameTitle = conversation.session?.title ?? ""
    renameOpen = true
  }
  /// Nova sessão inheriting this session's project, checkout and model (the … menu and the switcher).
  private func startNewSession() {
    let draft = sessions.drafts.draft(conversation.id)
    draft.focused = false
    leavePosition()
    let origin = conversation.session.flatMap {
      NewSessionOrigin(session: $0, projects: sessions.projects, chatRoot: sessions.chatRoot,
        model: draft.model ?? $0.model)
    }
    sessions.conversationPath.append(
      .init(id: "draft_" + UUID().uuidString, newSession: true, origin: origin))
  }
  /// Replaces this conversation in place, so Back still returns to Sessões.
  private func switchSession(to id: String) {
    guard id != conversation.id,
      let index = sessions.conversationPath.lastIndex(where: {
        $0.id == conversation.id && !$0.agents && !$0.newSession && !$0.master
      })
    else { return }
    leavePosition()
    sessions.conversationPath.replaceSubrange(index..., with: [.init(id: id)])
  }
  private var timeline: some View {
    TranscriptHost(
      store: conversation, reading: sessions.reading, size: size,
      // While reading aloud, the end of the transcript sits above the player.
      bottomPadding: 12 + (readAloudHeight > 0 ? readAloudHeight + 12 : 0),
      openChild: { openChild($0) }, openNote: { note = TranscriptNote(part: $0, id: $1) },
      canPersist: { !sessions.deletedIDs.contains(conversation.id) }, pagingSuspended: search.open)
    .background(theme.color(.background))
    .onChange(of: conversation.readingRequest) { _, request in
      guard let request else { return }
      // A quote's passage may be gone or changed: say so once its message is shown, or found missing.
      transcript?.reveal(messageID: request.messageID, offset: request.offset, persist: request.persist) { _ in
        if screenVisible { validateQuoteTarget() }
      }
    }
    .task(id: "\(conversation.hasTranscript):\(requestedEnd)") {
      guard conversation.hasTranscript, requestedEnd else { return }
      requestedEnd = false
      transcript?.scrollToLatest(animated: false)
    }
    .task(id: "\(conversation.hasTranscript):\(requestedTool ?? "")") {
      guard conversation.hasTranscript, let tool = requestedTool else { return }
      requestedTool = nil
      transcript?.revealTool(tool)
    }
    .overlay(alignment: .bottomTrailing) {
      ConversationBottomControls(
        readAloud: conversation.readAloud, state: conversation.memory.state,
        jump: { transcript?.scrollToLatest(animated: true) },
        reveal: { conversation.revealMessage($0, persist: false) }, height: { readAloudHeight = $0 })
    }
    .overlay(alignment: .top) {
      ConversationViewportNotices(state: conversation.memory.state) { transcript?.resume() }
    }
    .overlay {
      if conversation.loading {
        ProgressView("Carregando conversa…").appFont(.caption)
      } else if conversation.memory.state.waitingForHistory {
        ProgressView("Restaurando leitura…").appFont(.caption)
      }
    }
    .sheet(item: $note) { note in TranscriptNoteSheet(note: note) }
    #if DEBUG
    .overlay(alignment: .bottomLeading) {
      if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureMeasureGrowth") {
        ScrollGrowthMeasurement(store: conversation) { transcript?.collectionView }.frame(width: 180, height: 40)
      }
    }
    .background {
      ConversationOpeningProbe(id: conversation.id, ready: conversation.hasTranscript && !conversation.memory.state.restoring)
        .frame(width: 1, height: 1)
    }
    .overlay(alignment: .topTrailing) {
      if ScrollFixtures.mode == "conversation", ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureFollow") {
        ConversationFollowFixture(store: conversation, color: theme.uiColor(.textStrong)) { transcript?.collectionView }
          .frame(width: 160, height: 40)
      }
    }
    #endif
  }
  private func revealQuote(_ quote: ChatQuote, mark: ChatQuoteMark? = nil) {
    quoteAligned = nil
    quoteTarget = mark ?? conversation.quoteIndex.marks(messageID: quote.messageID, partID: quote.partID)
      .first { $0.quote.id == quote.id } ?? ChatQuoteMark(quote: quote, number: 1)
    quoteRevealTask?.cancel()
    quoteRevealed = quoteTarget?.id
    conversation.revealMessage(quote.messageID, persist: false)
  }
  /// The quoted passage being revealed must still exist and still match its quote.
  private func validateQuoteTarget() {
    guard let mark = quoteTarget else { return }
    quoteValidation?.cancel()
    quoteValidation = Task { @MainActor in
      guard let message = conversation.activity.messages.first(where: { $0.message.id == mark.quote.messageID })?.message,
        let entry = (message.content ?? []).enumerated().first(where: { message.partID(at: $0.offset) == mark.quote.partID }),
        let source = entry.element.text else {
        conversation.toast.show("O trecho citado não está mais disponível.")
        quoteTarget = nil
        quoteRevealed = nil
        return
      }
      let blocks = await ResponseMarkdownCache.shared.parse(source)
      guard !Task.isCancelled else { return }
      if ChatQuoteAnchoring.sourceRanges(mark.quote, source: source, blocks: blocks).isEmpty {
        conversation.toast.show("O trecho citado foi alterado e não pode ser marcado.")
        quoteTarget = nil
        quoteRevealed = nil
      }
    }
  }
  private func openChild(_ id: String) {
    leavePosition()
    sessions.conversationPath.append(.init(id: id, parent: conversation.id))
  }
  private func leavePosition() {
    // Capture before NavigationStack changes safe areas; its later disappearance
    // callbacks must not overwrite that snapshot with transition geometry.
    guard screenVisible else { return }
    transcript?.capture()
    screenVisible = false
  }
}

/// Observes the composer trigger in a leaf, so a suggestion query typed in the composer
/// does not re-render the conversation and diff its transcript list.
private struct DraftTriggerObserver: View {
  let draft: ConversationDraft
  let changed: () -> Void
  var body: some View {
    Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
      .onChange(of: draft.trigger) { _, _ in changed() }
  }
}
