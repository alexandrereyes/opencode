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
  var nearBottom: Bool { height - offset - viewport < 80 }
}
@MainActor private final class ConversationScrollState {
  var offset: CGFloat = 0
  var rows: [String: CGFloat] = [:]
  var anchor: (id: String, y: CGFloat)?
  weak var view: UIScrollView?
  var nearBottom = true
  func followToEnd() {
    guard let view else { return }
    let y = max(
      -view.adjustedContentInset.top,
      view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
    if abs(view.contentOffset.y - y) > 1 {
      view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
    }
  }
}
private struct ConversationScrollProbe: UIViewRepresentable {
  let state: ConversationScrollState
  let color: UIColor
  func makeUIView(context: Context) -> Probe { Probe(state: state, color: color) }
  func updateUIView(_ view: Probe, context: Context) {
    view.color = color
    state.view?.backgroundColor = color
  }
  final class Probe: UIView {
    let state: ConversationScrollState
    var color: UIColor
    init(state: ConversationScrollState, color: UIColor) {
      self.state = state
      self.color = color
      super.init(frame: .zero)
      isOpaque = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      var parent = superview
      while let current = parent {
        if let scroll = current as? UIScrollView {
          state.view = scroll
          scroll.backgroundColor = color
          return
        }
        parent = current.superview
      }
    }
  }
}
private struct PinnedHeaderProbe: UIViewRepresentable {
  let update: (Bool) -> Void
  func makeUIView(context: Context) -> Probe { Probe(update: update) }
  func updateUIView(_ view: Probe, context: Context) {
    view.update = update
    view.refresh()
  }
  final class Probe: UIView {
    var update: (Bool) -> Void
    weak var scroll: UIScrollView?
    weak var container: UICollectionReusableView?
    var observation: NSKeyValueObservation?
    var pinned = false
    init(update: @escaping (Bool) -> Void) {
      self.update = update
      super.init(frame: .zero)
      isOpaque = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      observation = nil
      container = nil
      var parent = superview
      while let current = parent {
        if container == nil, let reusable = current as? UICollectionReusableView {
          container = reusable
        }
        if let view = current as? UIScrollView {
          scroll = view
          observation = view.observe(\.contentOffset, options: [.initial, .new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
          }
          return
        }
        parent = current.superview
      }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      refresh()
    }
    func refresh() {
      guard let scroll, let container, container.bounds.height > 0, window != nil else { return }
      let frame = container.convert(container.bounds, to: scroll)
      // List prefetches headers above the viewport; only the header crossing its
      // top edge is sticky, not every previously visited prompt.
      let next =
        scroll.contentOffset.y > -scroll.adjustedContentInset.top + 1
        && frame.minY - scroll.bounds.minY <= 2 && frame.maxY > scroll.bounds.minY + 1
      guard next != pinned else { return }
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
  @State private var userScrolling = false
  @State private var firstLoad = true
  @State private var scrollState = ConversationScrollState()
  @State private var agentsOpen = false
  @State private var contextOpen = false
  @State private var requestedTool: String?
  @State private var childTool: String?
  let sessions: SessionStore
  let parentOnStack: String?

  init(id: String, sessions: SessionStore, parentOnStack: String? = nil, toolID: String? = nil) {
    self.sessions = sessions
    self.parentOnStack = parentOnStack
    _requestedTool = State(initialValue: toolID)
    _conversation = State(
      initialValue: ConversationStore(id: id, client: sessions.client, hub: sessions.hub))
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
          })
    }
    .background(theme.color(.background))
    .environment(conversation.toast)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let parent = conversation.session?.parentID {
        VStack(spacing: 6) {
          Text("Não é possível enviar mensagens diretamente a subagentes.").font(.footnote)
          Button("Voltar à sessão principal") {
            if parentOnStack == parent { dismiss() } else { child = parent }
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
    .toolbar(.hidden, for: .navigationBar, .tabBar)
    .navigationDestination(item: $child) { id in
      ConversationView(
        id: id, sessions: sessions, parentOnStack: conversation.id, toolID: childTool)
    }
    .sheet(isPresented: $agentsOpen) {
      ConversationAgentsSheet(store: conversation) { work in
        if let id = work.sessionID {
          childTool = nil
          child = id
        } else if let tool = work.toolID {
          if let parent = conversation.session?.parentID {
            childTool = tool
            child = parent
          } else {
            conversation.revealedToolID = tool
            requestedTool = tool
          }
        }
      }
    }
    .sheet(isPresented: $contextOpen) { ConversationContextSheet(store: conversation) }
    .task(id: scenePhase) { if scenePhase == .active { await conversation.run() } }
    .task(id: conversation.revision) { await conversation.presented() }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { Task { await sessions.drafts.draft(conversation.id).persist() } }
    }
  }
  private var header: some View {
    HStack(spacing: 9) {
      Button {
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
        Button("Alterações", systemImage: "square.and.pencil") {}.disabled(true)
        Button("Arquivos", systemImage: "folder") {}.disabled(true)
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
      List {
        if conversation.hasOlder && conversation.ready {
          HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
          }
          .padding(.vertical, 6)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
          .accessibilityLabel("Carregando mensagens anteriores")
          .onAppear { if !firstLoad { loadOlder() } }
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
                  message: message, footer: hasFooter(message), store: conversation
                ) { child = $0 }
              }
              .padding(.vertical, 10)
              .background(theme.color(.background))
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
              .listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
              .id(message.id)
              .background(
                ConversationScrollProbe(state: scrollState, color: theme.uiColor(.background))
              )
              .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("conversation-scroll")).minY
              } action: { _, y in
                scrollState.rows[message.id] = y
                if let view = scrollState.view,
                  view.isTracking || view.isDragging || view.isDecelerating
                {
                  scrollState.anchor = nil
                }
                if let anchor = scrollState.anchor, anchor.id == message.id, abs(y - anchor.y) > 1 {
                  if let view = scrollState.view {
                    view.setContentOffset(
                      CGPoint(x: view.contentOffset.x, y: view.contentOffset.y + y - anchor.y),
                      animated: false)
                  }
                }
              }
              .onDisappear { scrollState.rows.removeValue(forKey: message.id) }
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
              .listRowSeparator(.hidden)
              .listRowBackground(theme.color(.background))
            }
          } header: {
            if let user = section.user {
              StickyUserHeader(
                message: user,
                day: showDay(user) ? ConversationProjection.day(user.time.created) : nil
              )
              .listRowInsets(EdgeInsets())
              .textCase(nil)
              .id(user.id)
              .listRowBackground(theme.color(.background))
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
      .listSectionSpacing(0)
      .environment(\.defaultMinListRowHeight, 0)
      .environment(\.defaultMinListHeaderHeight, 0)
      .scrollContentBackground(.hidden)
      .background(theme.color(.background))
      .accessibilityIdentifier("conversation-transcript")
      .accessibilityValue("\(conversation.messages.count) mensagens carregadas")
      .coordinateSpace(name: "conversation-scroll")
      .onScrollPhaseChange { _, phase in
        if phase == .tracking || phase == .interacting || phase == .decelerating {
          scrollState.anchor = nil
          userScrolling = true
          atBottom = false
        }
        if phase == .idle {
          if userScrolling { atBottom = scrollState.nearBottom }
          userScrolling = false
        }
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
        ConversationScrollMetrics(
          height: geometry.contentSize.height, offset: geometry.visibleRect.minY,
          viewport: geometry.visibleRect.height)
      } action: { old, new in
        scrollState.offset = new.offset
        scrollState.nearBottom = new.nearBottom
        let interacting =
          userScrolling
          || scrollState.view.map { $0.isTracking || $0.isDragging || $0.isDecelerating } == true
        if interacting { scrollState.anchor = nil }
        if new.offset < 40 && !firstLoad { loadOlder() }
        if (old.height != new.height || old.viewport != new.viewport) && atBottom && !interacting {
          proxy.scrollTo("bottom", anchor: .bottom)
          scrollState.followToEnd()
        } else {
          // Layout/measurement changes are not a user request to stop following.
          atBottom = ConversationProjection.followTail(
            current: atBottom, interacting: interacting, nearBottom: new.nearBottom)
        }
      }
      .onChange(of: conversation.revision) { _, _ in
        if let tool = requestedTool,
          let message = conversation.messages.first(where: { $0.tools.contains { $0.id == tool } })
        {
          conversation.revealedToolID = tool
          atBottom = false
          firstLoad = false
          proxy.scrollTo(message.id, anchor: .center)
          requestedTool = nil
          return
        }
        if firstLoad && conversation.ready {
          Task { @MainActor in
            await Task.yield()
            guard firstLoad else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
            scrollState.followToEnd()
            firstLoad = false
            if let view = scrollState.view, view.contentSize.height <= view.bounds.height {
              loadOlder()
            }
          }
        } else if atBottom && !userScrolling
          && scrollState.view.map({ !$0.isTracking && !$0.isDragging && !$0.isDecelerating })
            != false
        {
          proxy.scrollTo("bottom", anchor: .bottom)
          scrollState.followToEnd()
        }
      }
      .onChange(of: requestedTool) { _, tool in
        guard let tool else { return }
        Task { @MainActor in
          while !conversation.messages.contains(where: { $0.tools.contains { $0.id == tool } })
            && conversation.hasOlder
          {
            await conversation.older()
            if conversation.error != nil { break }
          }
          if let message = conversation.messages.first(where: {
            $0.tools.contains { $0.id == tool }
          }) {
            atBottom = false
            proxy.scrollTo(message.id, anchor: .center)
          }
          requestedTool = nil
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if !atBottom {
          Button {
            scrollState.anchor = nil
            atBottom = true
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
          } label: {
            Image(systemName: "arrow.down").frame(width: 42, height: 42)
          }.buttonStyle(.glass).buttonBorderShape(.circle).padding(12).accessibilityLabel(
            "Ir para o fim")
        }
      }
      .overlay { if conversation.loading { ProgressView("Carregando conversa…").font(.footnote) } }
    }
  }
  private var line: some View { Rectangle().fill(theme.color(.border)).frame(height: 0.5) }
  private func loadOlder() {
    guard conversation.ready, conversation.hasOlder, !conversation.paging else { return }
    // Retain a row's actual screen coordinate, including a partially visible page, not just its ID.
    if !atBottom,
      let anchor = scrollState.rows.filter({ $0.value >= 0 }).min(by: { $0.value < $1.value })
    {
      scrollState.anchor = (anchor.key, anchor.value)
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
  @State private var pinned = false
  var body: some View {
    VStack(spacing: 10) {
      if let day, !pinned {
        Text(day).font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).padding(6)
          .background(theme.color(.codeSurface), in: Capsule())
      }
      UserBubble(message: message, compact: pinned)
    }
    .padding(.vertical, 6).padding(.horizontal, 16).background(theme.color(.background))
    .background(PinnedHeaderProbe { pinned = $0 })
    .overlay(alignment: .bottom) {
      if pinned {
        LinearGradient(
          colors: [theme.color(.background), theme.color(.background).opacity(0)], startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 14).offset(y: 14).allowsHitTesting(false)
      }
    }
  }
}

private struct ConversationMessageView: View {
  @Environment(\.appTheme) private var theme
  let message: ConversationMessage
  let footer: Bool
  let store: ConversationStore
  let openChild: (String) -> Void
  private struct Chunk: Identifiable {
    let id: String
    let parts: [ConversationPart]
    let text: String?
  }
  private var chunks: [Chunk] {
    var result: [Chunk] = []
    var activity: [ConversationPart] = []
    for (index, part) in (message.content ?? []).enumerated() {
      if part.type == "text" {
        if !activity.isEmpty {
          result.append(Chunk(id: "step:\(result.count)", parts: activity, text: nil))
          activity = []
        }
        result.append(Chunk(id: message.partID(at: index)!, parts: [], text: part.text))
      } else {
        activity.append(part)
      }
    }
    if !activity.isEmpty {
      result.append(Chunk(id: "step:\(result.count)", parts: activity, text: nil))
    }
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      if message.type == "assistant" {
        ForEach(chunks) { chunk in
          if let text = chunk.text, !text.isEmpty {
            ResponseMarkdown(text: text, messageID: message.id, partID: chunk.id)
          } else if !chunk.parts.isEmpty {
            ConversationStep(parts: chunk.parts, store: store, openChild: openChild)
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
        ConversationStep(parts: message.tools, store: store, openChild: openChild)
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
