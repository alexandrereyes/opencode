import OpenCodeKit
import SwiftUI

private struct ConversationSection: Identifiable {
  let id: String
  let user: ConversationMessage?
  var messages: [ConversationMessage]
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
  let update: (Bool) -> Void
  func makeUIView(context: Context) -> Probe {
    Probe(id: id, state: state, color: color, update: update)
  }
  func updateUIView(_ view: Probe, context: Context) {
    let changed = view.id != id
    view.id = id
    view.state = state
    view.color = color
    view.update = update
    view.attach()
    view.refresh(force: changed)
  }
  static func dismantleUIView(_ view: Probe, coordinator: ()) { view.fade.removeFromSuperlayer() }
  final class Probe: UIView {
    var update: (Bool) -> Void
    var id: String
    var state: ConversationScrollState
    var color: UIColor
    weak var scroll: UIScrollView?
    weak var container: UICollectionReusableView?
    var observation: NSKeyValueObservation?
    var pinned = false
    let fade = CAGradientLayer()
    init(
      id: String, state: ConversationScrollState, color: UIColor, update: @escaping (Bool) -> Void
    ) {
      self.id = id
      self.state = state
      self.color = color
      self.update = update
      super.init(frame: .zero)
      isOpaque = false
      fade.startPoint = CGPoint(x: 0.5, y: 0)
      fade.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      observation = nil
      if window == nil { fade.removeFromSuperlayer() }
      attach()
      refresh(force: true)
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
            observation = view.observe(\.contentOffset, options: [.initial, .new]) {
              [weak self] _, _ in
              Task { @MainActor [weak self] in self?.refresh() }
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
    func refresh(force: Bool = false) {
      guard let scroll, let container, container.bounds.height > 0, window != nil else { return }
      container.backgroundColor = color
      if let cell = container as? UICollectionViewListCell,
        cell.backgroundConfiguration?.backgroundColor != color
          || cell.backgroundConfiguration?.visualEffect != nil
      {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = color
        background.backgroundInsets = .zero
        cell.automaticallyUpdatesBackgroundConfiguration = false
        cell.backgroundConfiguration = background
      }
      state.registerHeader(self, container: container, id: id)
      let frame = container.convert(container.bounds, to: scroll)
      // List prefetches headers above the viewport; only the header crossing its
      // top edge is sticky, not every previously visited prompt.
      let next =
        scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1
        && frame.minY - scroll.bounds.minY <= 2 && frame.maxY > scroll.bounds.minY + 1
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
      fade.frame = CGRect(x: 0, y: container.bounds.maxY, width: container.bounds.width, height: 14)
      fade.colors = [
        color.resolvedColor(with: container.traitCollection).cgColor,
        color.withAlphaComponent(0).resolvedColor(with: container.traitCollection).cgColor,
      ]
      fade.isHidden = !next
      CATransaction.commit()
      guard force || next != pinned else { return }
      pinned = next
      Task { @MainActor [weak self] in
        guard let self else { return }
        update(pinned)
      }
    }
  }
}

struct ConversationView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var conversation: ConversationStore
  @State private var child: String?
  @State private var atBottom = true
  @State private var selectionPaused = false
  @State private var userScrolling = false
  @State private var firstLoad = true
  @State private var scrollState = ConversationScrollState()
  @State private var agentsOpen = false
  @State private var contextOpen = false
  @State private var detailsOpen = false
  @State private var renameOpen = false
  @State private var renameTitle = ""
  @State private var archiveOpen = false
  @State private var search = ConversationSearchState()
  @State private var requestedTool: String?
  @State private var childTool: String?
  @State private var savedPosition: ReadingPosition?
  @State private var restoring = false
  @State private var resumeOffered = false
  @State private var restorationTask: Task<Void, Never>?
  @State private var captureTask: Task<Void, Never>?
  @State private var captureRequested = false
  @State private var unreadAbove = false
  @State private var stickyHeight: CGFloat = 0
  @State private var screenVisible = true
  let initialFollowTail: Bool
  let sessions: SessionStore
  let parentOnStack: String?

  init(id: String, sessions: SessionStore, parentOnStack: String? = nil, toolID: String? = nil) {
    self.sessions = sessions
    self.parentOnStack = parentOnStack
    _requestedTool = State(initialValue: toolID)
    let position = sessions.reading.position(id)
    _savedPosition = State(initialValue: position)
    initialFollowTail = position?.target == nil || position?.target == .followTail
    _atBottom = State(initialValue: initialFollowTail && toolID == nil)
    _conversation = State(
      initialValue: ConversationStore(
        id: id, client: sessions.client, hub: sessions.hub,
        expansions: sessions.expansions))
  }
  private var sections: [ConversationSection] {
    var result = [ConversationSection(id: "leading", user: nil, messages: [])]
    for message in conversation.messages {
      if message.type == "user" {
        result.append(ConversationSection(id: message.id, user: message, messages: []))
      } else {
        result[result.count - 1].messages.append(message)
      }
    }
    return result
  }
  var body: some View {
    VStack(spacing: 0) {
      header
      if let notice = conversation.notice {
        ConversationNoticeView(notice: notice) { Task { await conversation.refresh() } }
      }
      if let error = conversation.error {
        Button {
          Task { await conversation.refresh() }
        } label: {
          Label(error, systemImage: "arrow.clockwise").font(.caption).foregroundStyle(
            theme.color(.error)
          ).padding(10)
        }
      }
      timeline.toastOverlay(conversation.toast)
        .simultaneousGesture(
          TapGesture().onEnded {
            sessions.drafts.draft(conversation.id).dismissSuggestions()
            sessions.drafts.draft(conversation.id).focused = false
          })
      bottomArea
    }
    .background(theme.color(.background))
    .environment(conversation.toast)
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
      conversation.session?.parentID == nil
        ? ResponseSelectionActions(
          comment: { quote in
            guard conversation.session?.parentID == nil else { return }
            let draft = sessions.drafts.draft(conversation.id)
            draft.focused = false
            draft.commenting = quote
          },
          sideQuestion: { text in
            sessions.drafts.draft(conversation.id).focused = false
            conversation.sideQuestion = SideQuestionLaunch(text: SideQuestionRequest.quote(text))
          }) : nil
    )
    .background(ConversationBackGesture(capture: leavePosition, appeared: { screenVisible = true }))
    .toolbar(.hidden, for: .navigationBar, .tabBar)
    .navigationDestination(item: $child) { id in
      ConversationView(
        id: id, sessions: sessions, parentOnStack: conversation.id, toolID: childTool)
    }
    .sheet(isPresented: $agentsOpen) {
      ConversationAgentsSheet(store: conversation) { work in
        if let id = work.sessionID {
          openChild(id)
        } else if let tool = work.toolID {
          if let parent = conversation.session?.parentID {
            childTool = tool
            leavePosition()
            child = parent
          } else {
            conversation.revealedToolID = tool
            requestedTool = tool
          }
        }
      }
    }
    .sheet(isPresented: $contextOpen) { ConversationContextSheet(store: conversation) }
    .sheet(isPresented: $detailsOpen) {
      SessionDetailsSheet(store: conversation, project: sessions.projects.first { $0.id == conversation.session?.projectID }) {
        contextOpen = true
      }
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
    .onChange(of: search.query) { _, _ in
      search.cancelPaging()
      search.update(conversation, reset: true)
    }
    .onChange(of: conversation.revision) { _, _ in
      if search.open { search.update(conversation) }
    }
    .task(id: scenePhase) { if scenePhase == .active { await conversation.run() } }
    .task(id: conversation.revision) { await conversation.presented() }
    .onAppear {
      screenVisible = true
      scrollState.correctAnchor()
    }
    .onDisappear {
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
        Task { await sessions.drafts.draft(conversation.id).persist() }
      }
    }
  }
  private var bottomArea: some View {
    Group {
      if search.open {
        ConversationSearchBar(search: search, store: conversation)
      } else if conversation.notice != nil {
        Text("Envio indisponível até resolver o aviso acima.").font(.footnote)
          .foregroundStyle(theme.color(.textSecondary)).padding(14).frame(maxWidth: .infinity)
      } else if let parent = conversation.session?.parentID {
        VStack(spacing: 6) {
          Text("Não é possível enviar mensagens diretamente a subagentes.").font(.footnote)
          Button("Voltar à sessão principal") {
            if parentOnStack == parent {
              leavePosition()
              dismiss()
            } else {
              openChild(parent)
            }
          }.font(.footnote.weight(.medium))
        }.foregroundStyle(theme.color(.textSecondary)).padding(14).frame(maxWidth: .infinity)
          .background(theme.color(.background))
      } else {
        VStack(spacing: 8) {
          ConversationTray(store: conversation, draft: sessions.drafts.draft(conversation.id))
          ConversationComposer(store: conversation, draft: sessions.drafts.draft(conversation.id))
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6).background(
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
        }.padding(.horizontal, 16).padding(.vertical, 8)
      } else { normalHeader }
    }.background(theme.color(.background))
  }
  private var normalHeader: some View {
    HStack(spacing: 9) {
      Button {
        leavePosition()
        dismiss()
      } label: {
        Image(systemName: "chevron.left").font(.system(size: 17, weight: .medium)).frame(
          width: 36, height: 36
        ).glassEffect(.regular.interactive(), in: .circle)
      }
      .buttonStyle(.plain).accessibilityLabel("Voltar")
      if let session = conversation.session {
        let project = sessions.projects.first { $0.id == session.projectID }
        let colors = theme.avatar(SessionList.avatarColor(project, fallback: session.projectID))
        Button {
          contextOpen = true
        } label: {
          ZStack {
            Circle().stroke(theme.color(.contextTrack), lineWidth: 2.5)
            if let fraction = conversation.context {
              Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(
                  theme.color(fraction > 0.8 ? .contextWarning : .contextFill),
                  style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            }
            Circle().fill(colors.background).padding(4)
            Text(
              SessionList.monogram(
                project?.displayName
                  ?? URL(fileURLWithPath: session.location.directory).lastPathComponent)
            )
            .font(.system(size: 14, weight: .medium)).foregroundStyle(colors.text)
          }.frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          conversation.context.map { "Contexto: \(Int(($0 * 100).rounded()))%" }
            ?? "Contexto desconhecido")
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(conversation.session?.displayTitle ?? "Conversa").font(
          .system(size: 14, weight: .semibold)
        ).lineLimit(1)
        Text(
          "\(Text(conversation.branch))\(Text(conversation.waiting ? " · aguardando você" : conversation.working ? " · trabalhando…" : "").foregroundColor(theme.color(conversation.waiting ? .error : .success)))"
        )
        .font(.system(size: 11)).lineLimit(1).foregroundStyle(theme.color(.textSecondary))
      }.frame(maxWidth: .infinity, alignment: .leading)
      if conversation.runningCount > 0 {
        Button {
          agentsOpen = true
        } label: {
          HStack(spacing: 6) {
            AgentPixels(color: theme.color(.success), size: 16)
            Text("\(conversation.runningCount)").font(.system(size: 13))
          }
          .padding(.horizontal, 9).frame(height: 36).glassEffect(
            .regular.interactive(), in: .capsule)
        }.buttonStyle(.plain).accessibilityLabel(
          conversation.runningCount == 1
            ? "1 agente em execução" : "\(conversation.runningCount) agentes em execução")
      }
      Menu {
        Button("Buscar na conversa", systemImage: "magnifyingglass") {
          sessions.drafts.draft(conversation.id).focused = false
          capturePosition()
          search.open = true
        }
        Button("Renomear", systemImage: "pencil") {
          renameTitle = conversation.session?.title ?? ""
          renameOpen = true
        }.disabled(conversation.session == nil)
        Button("Detalhes da sessão", systemImage: "info.circle") { detailsOpen = true }
          .disabled(conversation.session == nil)
        if conversation.session?.parentID == nil {
          Divider()
          Button("Arquivar", systemImage: "archivebox", role: .destructive) { archiveOpen = true }
            .disabled(conversation.session == nil || conversation.acting.contains("archive"))
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 19)).frame(width: 36, height: 36)
          .glassEffect(.regular.interactive(), in: .circle)
      }
      .buttonStyle(.plain).accessibilityLabel("Mais opções")
    }
    .foregroundStyle(theme.color(.textStrong)).padding(.horizontal, 12).padding(.vertical, 8)
    .background(theme.color(.background))
  }
  private var timeline: some View {
    ScrollViewReader { proxy in
      let dividers = ConversationProjection.finalAnswerDividers(conversation.messages)
      List {
        if conversation.hasOlder && conversation.ready && !resumeOffered {
          HStack {
            Spacer()
            if conversation.paging || restoring {
              ProgressView().controlSize(.small)
            } else {
              Button("Mensagens anteriores") { loadOlder() }.font(.caption)
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
          .onAppear { if !search.open && !firstLoad && !restoring && !resumeOffered { loadOlder() } }
        }
        ForEach(sections) { section in
          Section {
            ForEach(section.messages) { message in
              VStack(alignment: .leading, spacing: 16) {
                if message.id
                  == ConversationProjection.unread(
                    conversation.messages, viewed: conversation.viewedBoundary)
                {
                  HStack {
                    line
                    Text("Novas mensagens").font(.system(size: 11))
                    line
                  }.foregroundStyle(theme.color(.primary))
                }
                if showDay(message) { day(message.time.created) }
                ConversationMessageView(
                  message: message, footer: hasFooter(message), store: conversation,
                  dividers: dividers
                ) { openChild($0) }
              }
              .padding(.vertical, 10)
              .background(theme.color(.background))
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
              .listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
              .id(message.id)
              .background(
                ConversationRowProbe(
                  state: scrollState, id: message.id, color: theme.uiColor(.background))
              )
              .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("conversation-scroll"))
              } action: { _, _ in
                scrollState.correctAnchor()
                updateUnread()
              }
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
              .listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
            }
          } header: {
            if let user = section.user {
              StickyUserHeader(
                message: user,
                day: showDay(user) ? ConversationProjection.day(user.time.created) : nil,
                scrollState: scrollState,
                pinnedChanged: { _ in
                  scrollState.correctAnchor()
                  updateUnread()
                }
              )
              .listRowInsets(EdgeInsets())
              .textCase(nil)
              .id(user.id)
              .listRowBackground(theme.color(.background))
              .background(
                ConversationRowProbe(
                  state: scrollState, id: user.id, color: theme.uiColor(.background))
              )
              .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("conversation-scroll"))
              } action: { _, _ in
                scrollState.correctAnchor()
                updateUnread()
              }
            }
          }
          .listSectionSeparator(.hidden)
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
        }
        ForEach(conversation.family?.permissions ?? []) { request in
          ConversationPermissionCard(request: request, store: conversation)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden).listRowBackground(theme.color(.background))
            .id(request.id)
        }
        ForEach(
          (conversation.family?.forms ?? []).filter { $0.metadata?["kind"]?.string == "question" }
        ) { form in
          ConversationQuestionCard(form: form, store: conversation)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden).listRowBackground(theme.color(.background))
            .id(form.id)
        }
        theme.color(.background).opacity(0).frame(height: 12).id("bottom")
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
        if !firstLoad && conversation.ready && requestedTool == nil {
          restore(savedPosition, proxy: proxy)
        }
      }
      .onScrollPhaseChange { _, phase in
        // Tracking also includes taps on the overlaid controls, not just scrolling.
        if phase == .interacting || phase == .decelerating {
          cancelRestoration()
          userScrolling = true
          atBottom = false
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
        scrollState.nearBottom = new.height - new.offset - new.viewport < 80
        let interacting =
          userScrolling
          || scrollState.view.map { $0.isTracking || $0.isDragging || $0.isDecelerating } == true
        if scrollState.view.map({ $0.isDragging || $0.isDecelerating }) == true
          && abs(new.offset - old.offset) > 1
        {
          captureRequested = true
          scrollState.cancelAnchor()
        }
        updateUnread()
        if !search.open && new.offset < 40 && !firstLoad && !restoring && !resumeOffered { loadOlder() }
        if (old.height != new.height || old.viewport != new.viewport) && atBottom && !interacting
          && !restoring
        {
          proxy.scrollTo("bottom", anchor: .bottom)
          scrollState.followToEnd()
        } else if !interacting {
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
        if firstLoad && conversation.ready {
          firstLoad = false
          restore(savedPosition, proxy: proxy)
        } else if atBottom && !userScrolling && !restoring && screenVisible
          && scrollState.view.map({ !$0.isTracking && !$0.isDragging && !$0.isDecelerating })
            != false
        {
          proxy.scrollTo("bottom", anchor: .bottom)
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
      .task(id: "\(conversation.ready):\(requestedTool ?? "")") {
        guard conversation.ready, let tool = requestedTool else { return }
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
        if !atBottom {
          Button {
            cancelRestoration()
            selectionPaused = false
            userScrolling = false
            atBottom = true
            captureRequested = true
            proxy.scrollTo("bottom", anchor: .bottom)
            Task { @MainActor in
              await Task.yield()
              scrollState.followToEnd()
            }
            scheduleCapture()
          } label: {
            Image(systemName: "arrow.down").frame(width: 42, height: 42)
          }.buttonStyle(.glass).buttonBorderShape(.circle).padding(12).accessibilityLabel(
            "Ir para o fim")
        }
      }
      .overlay(alignment: .top) {
        VStack(spacing: 8) {
          if resumeOffered {
            Button("Retomar leitura") { restore(savedPosition, proxy: proxy) }
              .buttonStyle(.glass)
          }
          if unreadAbove,
            let id = ConversationProjection.unread(
              conversation.messages, viewed: conversation.viewedBoundary)
          {
            Button("Novas mensagens ↑") {
              conversation.revealMessage(id)
            }.buttonStyle(.glass).accessibilityLabel("Ir às novas mensagens")
          }
        }.font(.caption).padding(.top, stickyHeight + 8)
      }
      .overlay { if conversation.loading { ProgressView("Carregando conversa…").font(.footnote) } }
    }
  }
  private var line: some View { Rectangle().fill(theme.color(.border)).frame(height: 0.5) }
  private func openChild(_ id: String) {
    leavePosition()
    childTool = nil
    child = id
  }
  private func leavePosition() {
    // Capture before NavigationStack changes safe areas; its later disappearance
    // callbacks must not overwrite that snapshot with transition geometry.
    guard screenVisible else { return }
    capturePosition()
    screenVisible = false
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
    guard screenVisible, conversation.ready, !firstLoad, !restoring, !resumeOffered else { return }
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
    let position = ReadingPosition(
      target, viewportTop: atBottom ? nil : Double(scrollState.usableTop))
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
  private func updateUnread() {
    stickyHeight = scrollState.usableTop
    guard
      let unread = ConversationProjection.unread(
        conversation.messages, viewed: conversation.viewedBoundary)
    else {
      unreadAbove = false
      return
    }
    if let frame = scrollState.frames[unread] {
      unreadAbove = frame.minY + 28 < scrollState.usableTop
      return
    }
    let frames = scrollState.frames
    let visible = conversation.messages.firstIndex {
      guard let frame = frames[$0.id], !scrollState.pinned.contains($0.id) else { return false }
      return frame.maxY > scrollState.usableTop
        && frame.minY < (scrollState.view?.bounds.height ?? 0)
    }
    unreadAbove =
      visible.map { index in
        conversation.messages[..<index].contains { $0.id == unread }
      } ?? false
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
          proxy.scrollTo("bottom", anchor: .bottom)
          await Task.yield()
          guard !Task.isCancelled else { return }
          scrollState.followToEnd()
          restoring = false
          if position?.target != .followTail {
            let tail = ReadingPosition(.followTail)
            savedPosition = tail
            sessions.reading.set(tail, sessionID: conversation.id)
            try? sessions.reading.flush()
          }
          updateUnread()
          return
        case .anchor(let id, let offset):
          await Task.yield()
          guard !Task.isCancelled else { return }
          proxy.scrollTo(id, anchor: .top)
          scrollState.anchor = nil
          scrollState.readingAnchor = (id, offset, position?.viewportTop)
          // Materialize the recycled row, then correct using real TextKit/image geometry.
          // The anchor remains active for late measurements, rotation and Dynamic Type.
          for _ in 0..<12 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            if scrollState.frames[id] == nil { proxy.scrollTo(id, anchor: .top) }
            scrollState.correctAnchor()
          }
          guard !Task.isCancelled else { return }
          restoring = false
          updateUnread()
          return
        }
      }
    }
  }
  private func loadOlder() {
    guard conversation.ready, conversation.hasOlder, !conversation.paging, !restoring,
      !resumeOffered
    else { return }
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
    Task {
      let count = conversation.messages.count
      await conversation.older()
      // An empty history page has no prepended geometry to preserve. In particular,
      // do not pin the top while the initial Markdown is still acquiring its height.
      if conversation.messages.count == count { scrollState.anchor = nil }
    }
  }
  private func showDay(_ message: ConversationMessage) -> Bool {
    guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }), index > 0
    else { return true }
    return !Calendar.current.isDate(
      Date(timeIntervalSince1970: message.time.created / 1000),
      inSameDayAs: Date(timeIntervalSince1970: conversation.messages[index - 1].time.created / 1000)
    )
  }
  private func day(_ milliseconds: Double) -> some View {
    Text(ConversationProjection.day(milliseconds)).font(.system(size: 11, weight: .medium))
      .foregroundStyle(theme.color(.textSecondary))
      .padding(.horizontal, 10).padding(.vertical, 5).background(
        theme.color(.codeSurface), in: Capsule()
      ).frame(maxWidth: .infinity)
  }
  private func hasFooter(_ message: ConversationMessage) -> Bool {
    guard message.type == "assistant", !message.responseText.isEmpty, message.time.completed != nil,
      message.error == nil, message.retry == nil,
      let index = conversation.messages.firstIndex(where: { $0.id == message.id })
    else { return false }
    let following = conversation.messages.dropFirst(index + 1).prefix { $0.type != "user" }
    guard !following.contains(where: { !$0.responseText.isEmpty }) else { return false }
    return conversation.messages.dropFirst(index + 1).contains { $0.type == "user" }
      || !conversation.working
  }
}

private struct StickyUserHeader: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let day: String?
  let scrollState: ConversationScrollState
  let pinnedChanged: (Bool) -> Void
  @State private var pinned = false
  var body: some View {
    VStack(spacing: 10) {
      if let day, !pinned {
        Text(day).font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).padding(6)
          .background(theme.color(.codeSurface), in: Capsule())
      }
      UserBubble(message: message, compact: pinned)
    }
    .padding(.vertical, 6).padding(.horizontal, 16)
    .background {
      // Native List headers inset their SwiftUI content. Paint beyond those margins,
      // otherwise the pinned backdrop cuts a rectangular hole in the response below.
      theme.color(.background).padding(.horizontal, -32)
    }
    .background(
      PinnedHeaderProbe(id: message.id, state: scrollState, color: theme.uiColor(.background)) {
        pinned = $0
        pinnedChanged($0)
      }
    )
  }
}

private struct ConversationMessageView: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let footer: Bool
  let store: ConversationStore
  let dividers: Set<String>
  let openChild: (String) -> Void
  private struct Chunk: Identifiable {
    let id: String
    let parts: [ConversationPart]
    let text: String?
  }
  private var chunks: [Chunk] {
    var result: [Chunk] = []
    var activity: [ConversationPart] = []
    var activityID = ""
    for (index, part) in (message.content ?? []).enumerated() {
      if part.suppressed { continue }
      if part.type == "text" {
        if !activity.isEmpty {
          result.append(Chunk(id: "step:\(activityID)", parts: activity, text: nil))
          activity = []
        }
        result.append(Chunk(id: message.partID(at: index)!, parts: [], text: part.text))
      } else {
        if activity.isEmpty { activityID = message.partID(at: index)! }
        activity.append(part)
      }
    }
    if !activity.isEmpty {
      result.append(Chunk(id: "step:\(activityID)", parts: activity, text: nil))
    }
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      if message.type == "assistant" {
        ForEach(chunks) { chunk in
          if let text = chunk.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              if dividers.contains(chunk.id) {
                Rectangle().fill(theme.color(.borderStrong)).frame(height: 1)
                  .accessibilityHidden(true)
              }
              ResponseMarkdown(text: text, messageID: message.id, partID: chunk.id)
            }
          } else if !chunk.parts.isEmpty {
            ConversationStep(
              parts: chunk.parts, id: "\(message.id):\(chunk.id)", store: store,
              openChild: openChild)
          }
        }
        if let error = message.error {
          Text(error.object?["message"]?.string ?? error.formatted).font(.footnote).foregroundStyle(
            theme.color(.error))
        }
        if let retry = message.retry {
          Text("Nova tentativa \(Int(retry.object?["attempt"]?.number ?? 0)) agendada").font(
            .footnote
          ).foregroundStyle(theme.color(.warning))
        }
        if footer {
          HStack(spacing: 10) {
            Text(ConversationProjection.footer(message, models: store.models)).font(
              .system(size: 11))
            Button {
              UIPasteboard.general.string = store.responseText(endingAt: message.id)
              store.toast.show("Resposta copiada")
            } label: {
              Image(systemName: "doc.on.doc").font(.system(size: 13))
            }
            .buttonStyle(.plain).accessibilityLabel("Copiar resposta")
          }.foregroundStyle(theme.color(.textSecondary))
        }
      } else if message.type == "shell" {
        ConversationStep(parts: message.tools, id: message.id, store: store, openChild: openChild)
      } else if message.type != "idle" || message.outcome == "interrupted"
        || message.outcome == "failed"
      {
        Text(message.notice).font(.system(size: 12)).foregroundStyle(
          theme.color(message.type == "idle" ? .warning : .textSecondary)
        )
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
