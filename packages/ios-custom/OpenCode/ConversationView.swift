import OpenCodeKit
import SwiftUI

private struct ConversationSection: Identifiable {
  let id: String
  let user: ConversationMessage?
  var messages: [ConversationActivityMessage]
}
private struct ConversationScrollMetrics: Equatable {
  let height: CGFloat
  let offset: CGFloat
  let viewport: CGFloat
}
private struct PinnedHeaderProbe: UIViewRepresentable {
  let id: String
  let state: ConversationScrollState
  let color: UIColor
  func makeUIView(context: Context) -> Probe {
    Probe(id: id, state: state, color: color)
  }
  func updateUIView(_ view: Probe, context: Context) {
    view.id = id
    view.state = state
    view.color = color
    view.attach()
    view.refresh()
  }
  static func dismantleUIView(_ view: Probe, coordinator: ()) { view.fade.removeFromSuperlayer() }
  final class Probe: UIView {
    var id: String
    var state: ConversationScrollState
    var color: UIColor
    weak var scroll: UIScrollView?
    weak var container: UICollectionReusableView?
    var observation: NSKeyValueObservation?
    let fade = CAGradientLayer()
    private var styled: Style?
    init(
      id: String, state: ConversationScrollState, color: UIColor
    ) {
      self.id = id
      self.state = state
      self.color = color
      super.init(frame: .zero)
      isOpaque = false
      fade.startPoint = CGPoint(x: 0.5, y: 0)
      fade.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      observation = nil
      if window == nil {
        fade.removeFromSuperlayer()
        styled = nil
      }
      attach()
      refresh()
    }
    override func didMoveToSuperview() {
      super.didMoveToSuperview()
      attach()
    }
    func attach() {
      container = nil
      var parent = superview
      while let current = parent {
        if container == nil, let reusable = current as? UICollectionReusableView {
          container = reusable
        }
        if let view = current as? UIScrollView {
          if scroll !== view || observation == nil {
            scroll = view
            // Offsets change on the main thread; the fade must follow in the same frame.
            observation = view.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
              MainActor.assumeIsolated { self?.reposition() }
            }
          }
          return
        }
        parent = current.superview
      }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      attach()
      refresh()
    }
    func refresh() {
      guard let container, container.bounds.height > 0, window != nil else { return }
      style(container)
      reposition()
    }
    /// Appearance depends only on the reused container, header and resolved color. Reapplying a cell
    /// background configuration rebuilds UIKit's background view, so it must not run per offset.
    private func style(_ container: UICollectionReusableView) {
      let resolved = color.resolvedColor(with: container.traitCollection)
      let key = Style(container: ObjectIdentifier(container), id: id, color: resolved.cgColor)
      guard styled != key || fade.superlayer !== container.layer else { return }
      styled = key
      container.backgroundColor = color
      if let cell = container as? UICollectionViewListCell {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = color
        background.backgroundInsets = .zero
        cell.automaticallyUpdatesBackgroundConfiguration = false
        cell.backgroundConfiguration = background
      }
      state.registerHeader(self, container: container, id: id)
      // The SwiftUI content is inset inside the native header. Its overlay starts
      // beneath opaque native padding, truncating most of the gradient. Draw from
      // the actual full-width header edge instead, without changing row geometry.
      if fade.superlayer !== container.layer {
        fade.removeFromSuperlayer()
        container.layer.addSublayer(fade)
      }
      container.clipsToBounds = false
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fade.colors = [resolved.cgColor, resolved.withAlphaComponent(0).cgColor]
      CATransaction.commit()
    }
    func reposition() {
      guard let scroll, let container, container.bounds.height > 0, window != nil,
        fade.superlayer === container.layer else { return }
      let frame = container.convert(container.bounds, to: scroll)
      // List prefetches headers above the viewport; only the header crossing its
      // top edge is sticky, not every previously visited prompt.
      let next =
        scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1
        && frame.minY - scroll.contentOffset.y <= 2 && frame.maxY > scroll.bounds.minY + 1
      let edge = CGRect(x: 0, y: container.bounds.maxY, width: container.bounds.width, height: 14)
      guard fade.frame != edge || fade.isHidden == next else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fade.frame = edge
      fade.isHidden = !next
      CATransaction.commit()
    }
    private struct Style: Equatable {
      let container: ObjectIdentifier
      let id: String
      let color: CGColor
    }
  }
}

struct ConversationView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.voiceController) private var voice
  @Environment(\.floatingVoice) private var floatingVoice
  @State private var conversation: ConversationStore
  @State private var atBottom = true
  @State private var selectionPaused = false
  @State private var userScrolling = false
  @State private var firstLoad = true
  @State private var scrollState = ConversationScrollState()
  @State private var contextOpen = false
  @State private var detailsOpen = false
  @State private var renameOpen = false
  @State private var renameTitle = ""
  @State private var archiveOpen = false
  @State private var deleteCandidate: Session?
  @State private var search = ConversationSearchState()
  @State private var requestedTool: String?
  @State private var savedPosition: ReadingPosition?
  @State private var restoring = false
  @State private var resumeOffered = false
  @State private var restorationTask: Task<Void, Never>?
  @State private var captureTask: Task<Void, Never>?
  @State private var captureRequested = false
  @State private var viewport = ConversationViewport()
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
  let initialFollowTail: Bool
  let sessions: SessionStore
  let parentOnStack: String?
  let master: Bool

  init(id: String, sessions: SessionStore, parentOnStack: String? = nil, toolID: String? = nil, master: Bool = false) {
    self.sessions = sessions
    self.master = master
    self.parentOnStack = parentOnStack
    _requestedTool = State(initialValue: toolID)
    let conversation = sessions.conversation(id, master: master)
    let position = sessions.reading.position(id)
    _savedPosition = State(initialValue: position)
    // A retained conversation returns to the exact passage it last showed, even one at the end.
    let resumed = conversation.hasTranscript && conversation.memory.anchor != nil
    initialFollowTail = !resumed && (position?.target == nil || position?.target == .followTail)
    _atBottom = State(initialValue: initialFollowTail && toolID == nil)
    _conversation = State(initialValue: conversation)
  }
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
  private var sections: [ConversationSection] {
    var result = [ConversationSection(id: "leading", user: nil, messages: [])]
    for item in conversation.activity.messages {
      let message = item.message
      if message.type == "user" {
        result.append(ConversationSection(id: message.id, user: message, messages: []))
      } else {
        result[result.count - 1].messages.append(item)
      }
    }
    return result
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
    .revertConfirmation($revertCandidate) { message in
      Task {
        await conversation.reversion.perform(target: message, store: conversation,
          draft: sessions.drafts.draft(conversation.id))
      }
    }
    // Only pinned prompts read this size; it changes on every frame of a keyboard transition.
    .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport.promptSize = $0 }
    .environment(\.conversationImages, conversation.session.map {
      ConversationImageContext(client: sessions.client, directory: $0.location.directory, sessionID: $0.id)
    })
    .environment(\.conversationSearch, ConversationSearchHighlight(matches: search.matches, current: search.current?.id, align: {
      search.align($0, offset: $1, store: conversation)
    }))
    .environment(
      \.responseSelectionChanged,
      ResponseSelectionObserver(selected: {
        let followed = atBottom
        let bookmark = scrollState.readingAnchor
        cancelRestoration()
        scrollState.readingAnchor = bookmark
        selectionPaused = true
        atBottom = false
        captureRequested = captureRequested || followed
        scheduleCapture()
      })
    )
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
    .background(ConversationBackGesture(capture: leavePosition, appeared: {
      screenVisible = true
      scrollState.setVisible(true)
      if atBottom { scrollState.followToEnd() }
      else { scrollState.correctAnchor() }
    }))
    .toolbar(.hidden, for: .navigationBar, .tabBar)
    .onChange(of: conversation.reversion.boundary(conversation.session)) { _, _ in
      conversation.updateActivity()
    }
    .onChange(of: conversation.toolRequest, initial: true) { _, tool in
      guard let tool else { return }
      conversation.toolRequest = nil
      conversation.revealedToolID = tool
      requestedTool = tool
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
    .onChange(of: restoring) { old, value in
      guard old, !value, !resumeOffered, screenVisible, let mark = quoteTarget else { return }
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
      screenVisible = true
      scrollState.setVisible(true)
      scrollState.correctAnchor()
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
      restorationTask?.cancel()
      if restoring { firstLoad = true }
      restoring = false
      captureTask?.cancel()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        captureTask?.cancel()
        capturePosition()
        freezePassage()
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
          if let parent = conversation.session?.parentID {
            Button("Voltar à sessão principal") {
              if parentOnStack == parent {
                leavePosition()
                // The parent may sit below its agents screen; return to the conversation itself.
                if let index = sessions.conversationPath.lastIndex(where: { $0.id == parent && !$0.agents && !$0.newSession }) {
                  sessions.conversationPath.removeSubrange((index + 1)...)
                } else { dismiss() }
              } else { openChild(parent) }
            }.appFont(.caption).foregroundStyle(theme.color(.textSecondary))
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
    return HStack(spacing: 9) {
      Button {
        leavePosition()
        dismiss()
      } label: {
        Image(systemName: "chevron.left").appSymbol(.navigation).frame(
          width: 36, height: 36
        ).glassEffect(.regular.interactive(), in: .circle)
      }
      .buttonStyle(.plain).accessibilityLabel("Voltar")
      if let session = conversation.session {
        let project = sessions.projects.first { $0.id == session.projectID }
        let colors = theme.avatar(SessionList.avatarColor(project, fallback: session.projectID))
        let monogram = SessionList.monogram(chat || project?.vcs == nil ? session.displayTitle : project?.displayName ?? session.displayTitle)
        Button {
          detailsOpen = true
        } label: {
          ZStack {
            Circle().stroke(theme.color(.contextTrack), lineWidth: 2.5)
            if let fraction = context {
              Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(
                  theme.color(fraction > 0.8 ? .contextWarning : .contextFill),
                  style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            }
            Circle().fill(master ? theme.color(.surface) : colors.background).padding(4)
            if master {
              Image(systemName: "point.3.connected.trianglepath.dotted")
                .appSymbol(.action).foregroundStyle(theme.color(.accent))
            } else {
              Text(monogram).appFont(.message, weight: .medium).foregroundStyle(colors.text)
                .lineLimit(1).minimumScaleFactor(0.5)
            }
          }.frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          context.map { "Contexto: \(Int(($0 * 100).rounded()))%" }
            ?? "Contexto desconhecido")
        .accessibilityIdentifier("conversation-header-avatar")
        .accessibilityValue(master ? "Sessão mestra" : monogram)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(master ? "Sessão mestra" : conversation.session?.displayTitle ?? "Conversa")
          .appFont(.navigation).lineLimit(1)
          .accessibilityIdentifier("conversation-header-title")
        if !headerSubtitle.isEmpty || !headerStatus.isEmpty {
          Text(
            "\(Text(headerSubtitle))\(Text(headerStatus.isEmpty ? "" : (headerSubtitle.isEmpty ? "" : " · ") + headerStatus).foregroundColor(theme.color(conversation.waiting ? .error : .success)))"
          )
          .appFont(.caption).lineLimit(1).foregroundStyle(theme.color(.textSecondary))
          .accessibilityIdentifier("conversation-header-subtitle")
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
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
      } else {
      ConversationOptionsMenu(
        sessionID: conversation.id, available: conversation.session != nil,
        canArchive: conversation.session?.parentID == nil, archiving: conversation.acting.contains("archive"),
        deleting: sessions.busy.contains(conversation.id),
        theme: theme,
        actions: .init(search: {
          sessions.drafts.draft(conversation.id).focused = false
          capturePosition()
          search.open = true
        }, rename: {
          renameTitle = conversation.session?.title ?? ""
          renameOpen = true
        }, details: {
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
        }, newSession: {
          let draft = sessions.drafts.draft(conversation.id)
          draft.focused = false
          leavePosition()
          let origin = conversation.session.flatMap {
            NewSessionOrigin(session: $0, projects: sessions.projects, chatRoot: sessions.chatRoot,
              model: draft.model ?? $0.model)
          }
          sessions.conversationPath.append(
            .init(id: "draft_" + UUID().uuidString, newSession: true, origin: origin))
        }))
        .frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: .circle)
      }
    }
    .foregroundStyle(theme.color(.textStrong)).padding(.horizontal, AppLayout.margin).padding(.vertical, 6)
    .background(theme.color(.background))
  }
  private var timeline: some View {
    ScrollViewReader { proxy in
      let dividers = ConversationProjection.finalAnswerDividers(conversation.messages)
      let marks = TranscriptMarks(conversation.messages, working: conversation.working)
      List {
        if conversation.hasOlder && conversation.hasTranscript && !resumeOffered {
          HStack {
            Spacer()
            if conversation.paging || restoring {
              ProgressView().controlSize(.small)
            } else {
              Button("Mensagens anteriores") { loadOlder() }.appFont(.caption)
                .foregroundStyle(theme.color(.textSecondary))
            }
            Spacer()
          }
          .padding(.vertical, 6)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
          .accessibilityLabel(
            conversation.paging || restoring
              ? "Carregando mensagens anteriores" : "Mensagens anteriores"
          )
          .onAppear { if !search.open && !atBottom && !firstLoad && !restoring && !resumeOffered { loadOlder() } }
        }
        ForEach(sections) { section in
          if let user = section.user, marks.days.contains(user.id) {
            day(user.time.created).padding(.vertical, 6)
              .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
          }
          Section {
            ForEach(section.messages) { item in
              let message = item.message
              VStack(alignment: .leading, spacing: 16) {
                if marks.days.contains(message.id) { day(message.time.created) }
                ConversationMessageView(
                  message: message, footer: hasFooter(message, marks: marks), store: conversation,
                  dividers: dividers, rows: item.rows
                ) { openChild($0) }.equatable()
              }
              .padding(.vertical, 10)
              .background(theme.color(.background))
              .listRowInsets(EdgeInsets(top: 0, leading: AppLayout.margin, bottom: 0, trailing: AppLayout.margin))
              .listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
              .id(message.id)
              .background(
                ConversationRowProbe(
                  state: scrollState, id: message.id, color: theme.uiColor(.background))
              )
              .onGeometryChange(for: CGSize.self) {
                $0.size
              } action: { _, _ in
                scrollState.correctAnchor()
                viewport.stickyHeight = scrollState.usableTop
              }
              .listRowInsets(EdgeInsets(top: 0, leading: AppLayout.margin, bottom: 0, trailing: AppLayout.margin))
              .listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
            }
          } header: {
            if let user = section.user {
              StickyUserHeader(
                message: user.presented(isChild: conversation.isChild),
                scrollState: scrollState, viewport: viewport
              ).equatable()
              .environment(\.userPromptJump, UserPromptJump { jumpToTurn($0) })
              .listRowInsets(EdgeInsets())
              .textCase(nil)
              .id(user.id)
              .listRowBackground(theme.color(.background))
              .background(
                ConversationRowProbe(
                  state: scrollState, id: user.id, color: theme.uiColor(.background))
              )
              .onGeometryChange(for: CGSize.self) {
                $0.size
              } action: { _, _ in
                scrollState.correctAnchor()
                viewport.stickyHeight = scrollState.usableTop
              }
            }
          }
          .listSectionSeparator(.hidden)
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
        }
        // Like delivered prompts, each pending one is a section header, so delivery swaps it in place.
        ForEach(conversation.pendingSteers) { item in
          Section {
          } header: {
            PendingUserMessage(item: item, store: conversation, viewport: viewport)
              .background { theme.color(.background).padding(.horizontal, -32) }
              .listRowInsets(EdgeInsets())
              .textCase(nil)
              .id(item.id)
              .onGeometryChange(for: CGSize.self) { $0.size } action: { _, _ in scrollState.correctAnchor() }
          }
          .listSectionSeparator(.hidden)
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
        }
        ForEach(conversation.family?.permissions ?? []) { request in
          ConversationPermissionCard(request: request, store: conversation)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: AppLayout.margin, bottom: 0, trailing: AppLayout.margin))
            .listRowSeparator(.hidden).listRowBackground(theme.color(.background))
            .id(request.id)
        }
        ForEach(
          (conversation.family?.forms ?? []).filter { $0.metadata?["kind"]?.string == "question" }
        ) { form in
          ConversationQuestionCard(form: form, store: conversation)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: AppLayout.margin, bottom: 0, trailing: AppLayout.margin))
            .listRowSeparator(.hidden).listRowBackground(theme.color(.background))
            .id(form.id)
        }
        // While reading aloud, the end of the transcript sits above the player.
        theme.color(.background).opacity(0).frame(height: 12 + (readAloudHeight > 0 ? readAloudHeight + 12 : 0)).id("bottom")
          .background(ConversationRowProbe(state: scrollState, id: "bottom", color: theme.uiColor(.background)))
          .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(
            theme.color(.background)
          )
      }
      .listStyle(.plain)
      .scrollDismissesKeyboard(.interactively)
      .listSectionSpacing(0)
      .environment(\.defaultMinListRowHeight, 0)
      .environment(\.defaultMinListHeaderHeight, 0)
      .scrollContentBackground(.hidden)
      .background(theme.color(.background))
      .accessibilityIdentifier("conversation-transcript")
      .accessibilityValue(
        firstLoad || restoring
          ? "Restaurando leitura" : "\(conversation.messages.count) mensagens carregadas"
      )
      .coordinateSpace(name: "conversation-scroll")
      .onAppear {
        scrollState.reveal = { proxy.scrollTo($0, anchor: .top) }
        // A retained conversation reopens at once from what it already holds; a screen covered by
        // another one is still where it was and is not restored again.
        if firstLoad && conversation.hasTranscript && requestedTool == nil {
          firstLoad = false
          restore(conversation.memory.anchor ?? savedPosition, proxy: proxy)
        }
      }
      .onScrollPhaseChange { _, phase in
        conversation.scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        // Tracking also includes taps on the overlaid controls, not just scrolling.
        if phase == .interacting || phase == .decelerating {
          conversation.mcps.close()
          cancelRestoration()
          userScrolling = true
          atBottom = false
          if phase == .interacting { scrollState.nearBottom = false }
        }
        if phase == .idle {
          if userScrolling && !selectionPaused { atBottom = scrollState.nearBottom }
          userScrolling = false
          scheduleCapture()
        }
      }
      .defaultScrollAnchor(initialFollowTail ? .bottom : .top, for: .initialOffset)
      .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
        ConversationScrollMetrics(
          height: geometry.contentSize.height, offset: geometry.visibleRect.minY,
          viewport: geometry.visibleRect.height)
      } action: { old, new in
        let geometry = ConversationScrollPlan.Viewport(
          height: new.height, offset: new.offset, viewport: new.viewport)
        let arrived = geometry.arrivedAtEnd(from: .init(
          height: old.height, offset: old.offset, viewport: old.viewport))
        viewport.jumpToLatest = geometry.jumpToLatest
        if !geometry.atEnd { scrollState.nearBottom = false }
        if arrived { scrollState.nearBottom = true }
        let interacting =
          userScrolling
          || scrollState.view.map { $0.isTracking || $0.isDragging || $0.isDecelerating } == true
        if scrollState.view.map({ $0.isDragging || $0.isDecelerating }) == true
          && abs(new.offset - old.offset) > 1
        {
          captureRequested = true
          scrollState.cancelAnchor()
        }
        viewport.stickyHeight = scrollState.usableTop
        // Following resumes only when the reader's own scroll ends at the end (scroll phase `idle`):
        // content shrinking or the viewport growing never starts it.
        // Fetching earlier admits pages while the reader is mid-history, where List's re-estimation of the
        // inserted rows shows; at the top, the held page lands where the reader expects it.
        if !search.open && !atBottom && new.offset < 40 && !firstLoad && !restoring && !resumeOffered { loadOlder() }
        if (old.height != new.height || old.viewport != new.viewport) && atBottom && !interacting
          && !restoring && screenVisible
        {
          scrollState.followToEnd()
        } else if !interacting && screenVisible {
          // A prepended page keeps re-estimating rows above the reader; hold the anchor in this frame.
          if old.height != new.height { scrollState.holdHistoryAnchor() }
          scrollState.correctAnchor()
        }
      }
      .onChange(of: conversation.revision) { _, _ in
        if let tool = requestedTool,
          let message = conversation.messages.first(where: { $0.tools.contains { $0.id == tool } })
        {
          conversation.revealedToolID = tool
          conversation.revealMessage(message.id)
          requestedTool = nil
          return
        }
        if firstLoad && conversation.hasTranscript {
          firstLoad = false
          restore(conversation.memory.anchor ?? savedPosition, proxy: proxy)
        } else if atBottom && !userScrolling && !restoring && screenVisible
          && scrollState.view.map({ !$0.isTracking && !$0.isDragging && !$0.isDecelerating })
            != false
        {
          scrollState.followToEnd()
        }
      }
      .onChange(of: conversation.readingRequest) { _, request in
        guard let request else { return }
        firstLoad = false
        restore(
          ReadingPosition(.message(id: request.messageID, offset: request.offset)), proxy: proxy,
          explicit: true, persist: request.persist)
      }
      .onChange(of: conversation.submitted) { _, _ in
        if screenVisible { resumeFollowing() }
      }
      .task(id: "\(conversation.hasTranscript):\(requestedTool ?? "")") {
        guard conversation.hasTranscript, let tool = requestedTool else { return }
        cancelRestoration()
        atBottom = false
        firstLoad = false
        while !conversation.messages.contains(where: { $0.tools.contains { $0.id == tool } })
          && conversation.hasOlder && !Task.isCancelled
        {
          if conversation.paging {
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            continue
          }
          await conversation.older()
          if conversation.error != nil { break }
        }
        guard !Task.isCancelled else { return }
        if let message = conversation.messages.first(where: { $0.tools.contains { $0.id == tool } })
        {
          conversation.revealedToolID = tool
          conversation.revealMessage(message.id)
        }
        requestedTool = nil
      }
      .overlay(alignment: .bottomTrailing) {
        ConversationBottomControls(
          readAloud: conversation.readAloud, viewport: viewport, jump: { resumeFollowing(animated: true) },
          reveal: { conversation.revealMessage($0, persist: false) }, height: { readAloudHeight = $0 })
      }
      .overlay(alignment: .top) {
        ConversationViewportNotices(
          viewport: viewport, offersResume: resumeOffered,
          resume: { restore(quoteTarget.map { ReadingPosition(.message(id: $0.quote.messageID, offset: 0)) } ?? savedPosition, proxy: proxy) })
      }
      .overlay { if conversation.loading { ProgressView("Carregando conversa…").appFont(.caption) } }
      #if DEBUG
      .overlay(alignment: .bottomLeading) {
        if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureMeasureGrowth") {
          ScrollGrowthMeasurement(store: conversation, state: scrollState).frame(width: 180, height: 40)
        }
      }
      .background { ConversationOpeningProbe(id: conversation.id, ready: conversation.hasTranscript).frame(width: 1, height: 1) }
      .overlay(alignment: .topTrailing) {
        if ScrollFixtures.mode == "conversation", ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureFollow") {
          ConversationFollowFixture(store: conversation, state: scrollState, color: theme.uiColor(.textStrong)).frame(width: 160, height: 40)
        }
      }
      #endif
    }
  }
  private func resumeFollowing(animated: Bool = false) {
    cancelRestoration()
    selectionPaused = false
    userScrolling = false
    atBottom = true
    captureRequested = true
    scrollState.followToEnd(animated: animated)
    scheduleCapture()
  }
  /// A pinned prompt returns to the first row of its turn, even when later steps followed it.
  private func jumpToTurn(_ prompt: String) -> Bool {
    guard let row = sections.first(where: { $0.user?.id == prompt })?.messages.first?.message.id
    else { return false }
    let jump = scrollState.revealTurn(prompt: prompt, row: row)
    switch jump {
    case .unpinned: return false
    case .repeated: return true
    case .settled:
      Haptics.play(.selection)
      return true
    case .scrolled, .unmeasured: break
    }
    // The scroll state already replaced its anchors; cancelling through it would stop the jump.
    restorationTask?.cancel()
    restorationTask = nil
    restoring = false
    resumeOffered = false
    selectionPaused = false
    userScrolling = false
    atBottom = false
    captureRequested = true
    if jump == .unmeasured { conversation.revealMessage(row) } else { scheduleCapture() }
    return true
  }
  private func revealQuote(_ quote: ChatQuote, mark: ChatQuoteMark? = nil) {
    quoteAligned = nil
    quoteTarget = mark ?? conversation.quoteIndex.marks(messageID: quote.messageID, partID: quote.partID)
      .first { $0.quote.id == quote.id } ?? ChatQuoteMark(quote: quote, number: 1)
    quoteRevealTask?.cancel()
    quoteRevealed = quoteTarget?.id
    conversation.revealMessage(quote.messageID, persist: false)
  }
  private func openChild(_ id: String) {
    leavePosition()
    sessions.conversationPath.append(.init(id: id, parent: conversation.id))
  }
  private func leavePosition() {
    // Capture before NavigationStack changes safe areas; its later disappearance
    // callbacks must not overwrite that snapshot with transition geometry.
    guard screenVisible else { return }
    capturePosition()
    if let exact = exactPosition() { conversation.memory.anchor = exact }
    screenVisible = false
    scrollState.setVisible(false)
  }
  /// The passage on screen as a message and offset, even at the end, for returning to it in this process.
  private func exactPosition() -> ReadingPosition? {
    guard conversation.hasTranscript, !firstLoad, !restoring, !resumeOffered,
      let target = scrollState.capture(followTail: false) else { return nil }
    let anchored: String? = if case .message(let id, _) = target { id } else { nil }
    return ReadingPosition(target, viewportTop: Double(scrollState.usableTop(excluding: anchored)))
  }
  /// Hiding the app keeps the exact passage: what arrives meanwhile lands outside it, and ↓ shows it.
  private func freezePassage() {
    guard screenVisible, let exact = exactPosition() else { return }
    conversation.memory.anchor = exact
    guard atBottom, case .message(let id, let offset) = exact.target else { return }
    atBottom = false
    scrollState.cancelAnchor()
    scrollState.readingAnchor = (id, offset, exact.viewportTop)
  }
  private func cancelRestoration() {
    restorationTask?.cancel()
    restorationTask = nil
    restoring = false
    resumeOffered = false
    scrollState.cancelAnchor()
  }
  private func scheduleCapture() {
    captureTask?.cancel()
    guard scenePhase == .active, screenVisible else { return }
    captureTask = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard scenePhase == .active else { return }
      capturePosition()
    }
  }
  private func capturePosition() {
    guard !sessions.deletedIDs.contains(conversation.id) else { return }
    guard screenVisible, conversation.hasTranscript, !firstLoad, !restoring, !resumeOffered else { return }
    // Restoring and layout are not new reading intent, including navigation's
    // safe-area changes. Never persist a drifted copy of a restored bookmark.
    if !captureRequested {
      if savedPosition == nil && atBottom {
        let position = ReadingPosition(.followTail)
        savedPosition = position
        sessions.reading.set(position, sessionID: conversation.id)
        try? sessions.reading.flush()
      }
      return
    }
    guard
      let target = scrollState.capture(followTail: atBottom)
    else { return }
    let anchored: String? = if case .message(let id, _) = target { id } else { nil }
    let position = ReadingPosition(
      target, viewportTop: atBottom ? nil : Double(scrollState.usableTop(excluding: anchored)))
    savedPosition = position
    sessions.reading.set(position, sessionID: conversation.id)
    captureRequested = false
    if case .message(let id, let offset) = target {
      scrollState.readingAnchor = (id, offset, position.viewportTop)
    }
    do { try sessions.reading.flush() } catch {
      conversation.toast.show("Não foi possível guardar a posição de leitura.", kind: .error)
    }
  }
  private func restore(_ position: ReadingPosition?, proxy: ScrollViewProxy, explicit: Bool = false, persist: Bool = true)
  {
    cancelRestoration()
    captureRequested = false
    if explicit && persist {
      savedPosition = position
      if let position {
        sessions.reading.set(position, sessionID: conversation.id)
        try? sessions.reading.flush()
      }
    }
    restoring = true
    atBottom = false
    restorationTask = Task { @MainActor in
      var pages = 0
      while !Task.isCancelled {
        let decision = ReadingRestoreDecision.decide(
          position,
          loaded: Set(conversation.messages.map(\.id)), hasOlder: conversation.hasOlder,
          pages: pages)
        switch decision {
        case .loadOlder:
          if conversation.paging {
            do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            continue
          }
          let count = conversation.messages.count
          await conversation.older()
          if Task.isCancelled { return }
          pages += 1
          if conversation.messages.count == count && conversation.error != nil {
            resumeOffered = true
            restoring = false
            return
          }
        case .offerResume:
          resumeOffered = true
          restoring = false
          return
        case .tail:
          scrollState.cancelAnchor()
          selectionPaused = false
          atBottom = true
          scrollState.followToEnd()
          // Publishing restoration early lets List's estimated zero offset page
          // backwards before the final cell has reached its real layout.
          while !scrollState.tailSettled {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
          }
          guard !Task.isCancelled else { return }
          restoring = false
          if position?.target != .followTail {
            let tail = ReadingPosition(.followTail)
            savedPosition = tail
            sessions.reading.set(tail, sessionID: conversation.id)
            try? sessions.reading.flush()
          }
          viewport.stickyHeight = scrollState.usableTop
          return
        case .anchor(let id, let offset):
          await Task.yield()
          guard !Task.isCancelled else { return }
          let anchorID = conversation.activity.anchors[id] ?? id
          if scrollState.frames[anchorID] == nil || scrollState.pinned.contains(anchorID) {
            proxy.scrollTo(anchorID, anchor: .top)
          }
          scrollState.anchor = nil
          scrollState.readingAnchor = (anchorID, offset, position?.viewportTop)
          // Materialize the recycled row, then correct using real TextKit/image geometry.
          // The anchor remains active for late measurements, rotation and Dynamic Type.
          for _ in 0..<12 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            if scrollState.frames[anchorID] == nil { proxy.scrollTo(anchorID, anchor: .top) }
            scrollState.correctAnchor()
          }
          guard !Task.isCancelled else { return }
          restoring = false
          viewport.stickyHeight = scrollState.usableTop
          return
        }
      }
    }
  }
  private func loadOlder() {
    guard conversation.hasTranscript, conversation.hasOlder, !conversation.paging, !restoring,
      !resumeOffered
    else { return }
    Task {
      let count = conversation.messages.count
      await conversation.older {
        // Like the web, a page fetched during a touch or fling waits until scrolling settles:
        // correcting a moving offset fights the gesture, and inserting without it jumps the rows.
        while scrollState.touching {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        // Retain a row's actual screen coordinate, including a partially visible page, not just its ID.
        if !atBottom,
          let anchor = scrollState.frames.filter({
            $0.value.maxY > scrollState.usableTop && !scrollState.pinned.contains($0.key)
          })
          .min(by: { $0.value.minY < $1.value.minY })
        {
          scrollState.readingAnchor = nil
          scrollState.anchor = (anchor.key, anchor.value.minY)
        }
      }
      // An empty history page has no prepended geometry to preserve. In particular,
      // do not pin the top while the initial Markdown is still acquiring its height.
      if conversation.messages.count == count { scrollState.anchor = nil }
      scrollState.correctAnchorNow()
    }
  }
  private func day(_ milliseconds: Double) -> some View {
    Text(ConversationProjection.day(milliseconds)).appFont(.footnote, weight: .medium)
      .foregroundStyle(theme.color(.textSecondary))
      .padding(.horizontal, 10).padding(.vertical, 5).background(
        theme.color(.codeSurface), in: Capsule()
      ).frame(maxWidth: .infinity)
  }
  private func hasFooter(_ message: ConversationMessage, marks: TranscriptMarks) -> Bool {
    message.type == "assistant" && marks.footers.contains(message.id) && message.time.completed != nil
      && message.error == nil && message.retry == nil && !message.responseText.isEmpty
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

private struct StickyUserHeader: View, @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.message == rhs.message && lhs.scrollState === rhs.scrollState && lhs.viewport === rhs.viewport
  }
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let scrollState: ConversationScrollState
  let viewport: ConversationViewport
  var body: some View {
    UserBubble(message: message, maximumTextHeight: viewport.promptSize.height * 0.4)
    // Native section headers add device-dependent margins independently of row insets.
    .frame(width: max(0, viewport.promptSize.width - AppLayout.margin * 2))
    .padding(.vertical, 8).frame(maxWidth: .infinity)
    .background {
      // Native List headers inset their SwiftUI content. Paint beyond those margins,
      // otherwise the pinned backdrop cuts a rectangular hole in the response below.
      theme.color(.background).padding(.horizontal, -32)
    }
    .background(
      PinnedHeaderProbe(id: message.id, state: scrollState, color: theme.uiColor(.background))
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-pinned-user")
  }
}

/// Streaming republishes the whole transcript; unchanged rows must not re-render, so equality ignores
/// the stable store and navigation handler.
private struct ConversationMessageView: View, @MainActor Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.message == rhs.message && lhs.footer == rhs.footer && lhs.rows == rhs.rows && lhs.dividers == rhs.dividers
  }
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let footer: Bool
  let store: ConversationStore
  let dividers: Set<String>
  let rows: [ConversationActivityRow]
  let openChild: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if message.type == "assistant" || !rows.isEmpty {
        ForEach(rows) { row in
          if row.kind == .text, let entry = row.parts.first {
            VStack(alignment: .leading, spacing: 12) {
              if dividers.contains(entry.id) {
                Rectangle().fill(theme.color(.borderStrong)).frame(height: 1)
                  .accessibilityHidden(true)
              }
              // Text rows belong to their own message; reading `store.messages` here would make every
              // visible row observe each streamed token.
              ResponseMarkdown(text: entry.part.text ?? "", messageID: entry.messageID, partID: entry.id)
                .environment(\.responseProse, true)
                .environment(\.responseFilesStable, entry.messageID == message.id
                  ? message.time.completed != nil
                  : store.messages.first { $0.id == entry.messageID }?.time.completed != nil)
            }
          } else if row.kind == .divider {
            Rectangle().fill(theme.color(.borderStrong)).frame(height: 1).accessibilityHidden(true)
          } else if !row.parts.isEmpty {
            ConversationStep(
              parts: row.parts.map(\.part), id: row.id, store: store,
              openChild: openChild, references: row.parts, items: row.items, grouped: row.kind == .group, busy: row.pending)
          }
        }
        if let error = message.error {
          Text(error.object?["message"]?.string ?? error.formatted).appFont(.caption).foregroundStyle(
            theme.color(.error))
        }
        if let retry = message.retry {
          Text("Nova tentativa \(Int(retry.object?["attempt"]?.number ?? 0)) agendada")
            .appFont(.caption).foregroundStyle(theme.color(.warning))
        }
        if footer {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
              Text(ConversationProjection.footer(message, models: store.displayModels))
                .appFont(.caption).monospacedDigit()
              Button {
                UIPasteboard.general.string = store.responseText(endingAt: message.id)
                Haptics.play(.selection)
                store.toast.show("Resposta copiada")
              } label: {
                Image(systemName: "doc.on.doc").appSymbol(.inline)
              }
              .buttonStyle(.plain).accessibilityLabel("Copiar resposta")
              Button {
                Haptics.play(.selection)
                store.readAloudResponse(endingAt: message.id)
              } label: {
                Image(systemName: "play").appSymbol(.inline)
              }
              .buttonStyle(.plain).accessibilityLabel("Ouvir resposta")
              .accessibilityIdentifier("read-aloud-message-" + message.id)
            }.foregroundStyle(theme.color(.textSecondary))
          }
        }
      } else if message.type == "shell" {
        ConversationStep(parts: message.tools, id: message.id, store: store, openChild: openChild)
      } else if message.type != "idle" || message.outcome == "interrupted"
        || message.outcome == "failed"
      {
        Text(message.notice).appFont(.caption).foregroundStyle(
          theme.color(message.type == "idle" ? .warning : .textSecondary)
        )
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
