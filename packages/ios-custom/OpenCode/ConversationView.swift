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
}

struct ConversationView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var conversation: ConversationStore
  @State private var child: String?
  @State private var atBottom = true
  @State private var firstLoad = true
  @State private var scrollPosition = ScrollPosition()
  @State private var scrollState = ConversationScrollState()
  @State private var scrolled = false
  let sessions: SessionStore
  let parentOnStack: String?

  init(id: String, sessions: SessionStore, parentOnStack: String? = nil) {
    self.sessions = sessions
    self.parentOnStack = parentOnStack
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
      timeline
    }
    .background(theme.color(.background))
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
        ConversationComposer(
          model: conversation.modelLabel, agent: conversation.session?.agent ?? "build"
        )
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6).background(
          theme.color(.background))
      }
    }
    .toolbar(.hidden, for: .navigationBar, .tabBar)
    .navigationDestination(item: $child) { id in
      ConversationView(id: id, sessions: sessions, parentOnStack: conversation.id)
    }
    .task(id: scenePhase) { if scenePhase == .active { await conversation.run() } }
    .task(id: conversation.revision) { await conversation.presented() }
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
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
          if conversation.hasOlder && conversation.ready {
            Button {
              loadOlder()
            } label: {
              HStack {
                Spacer()
                if conversation.paging {
                  ProgressView()
                } else {
                  Text("Carregar mensagens anteriores")
                }
                Spacer()
              }.font(.footnote)
            }.padding(.top, 8)
              .onAppear {
                guard !firstLoad, !atBottom else { return }
                loadOlder()
              }
          }
          ForEach(sections) { section in
            Section {
              ForEach(section.messages) { message in
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
                .id(message.id)
                .onGeometryChange(for: CGFloat.self) {
                  $0.frame(in: .named("conversation-scroll")).minY
                } action: { _, y in
                  scrollState.rows[message.id] = y
                  if let anchor = scrollState.anchor, anchor.id == message.id, abs(y - anchor.y) > 1
                  {
                    scrollPosition.scrollTo(y: scrollState.offset + y - anchor.y)
                  }
                }
              }
            } header: {
              if let user = section.user {
                StickyUserHeader(
                  message: user,
                  day: showDay(user) ? ConversationProjection.day(user.time.created) : nil,
                  scrolled: scrolled
                )
                .id(user.id)
              }
            }
          }
          theme.color(.background).opacity(0).frame(height: 1).id("bottom")
        }
        .scrollTargetLayout()
        .padding(.horizontal, 16).padding(.bottom, 12)
      }
      .coordinateSpace(name: "conversation-scroll")
      .scrollPosition($scrollPosition)
      .onScrollPhaseChange { _, phase in
        if phase == .tracking || phase == .interacting || phase == .decelerating {
          scrollState.anchor = nil
          atBottom = false
        }
      }
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .onScrollGeometryChange(for: ConversationScrollMetrics.self) { geometry in
        ConversationScrollMetrics(
          height: geometry.contentSize.height, offset: geometry.contentOffset.y,
          viewport: geometry.containerSize.height)
      } action: { old, new in
        scrollState.offset = new.offset
        scrolled = new.offset > 1
        if old.height != new.height && atBottom {
          proxy.scrollTo("bottom", anchor: .bottom)
        } else {
          atBottom = new.nearBottom
        }
      }
      .onChange(of: conversation.revision) { _, _ in
        if firstLoad && conversation.ready {
          proxy.scrollTo("bottom", anchor: .bottom)
          firstLoad = false
        } else if atBottom {
          proxy.scrollTo("bottom", anchor: .bottom)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if !atBottom {
          Button {
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
    guard !conversation.paging else { return }
    // Retain a row's actual screen coordinate, including a partially visible page, not just its ID.
    if let anchor = scrollState.rows.filter({ $0.value >= 0 }).min(by: { $0.value < $1.value }) {
      scrollState.anchor = (anchor.key, anchor.value)
    }
    Task { await conversation.older() }
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
  let scrolled: Bool
  @State private var pinned = false
  var body: some View {
    VStack(spacing: 10) {
      if let day, !pinned {
        Text(day).font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary)).padding(6)
          .background(theme.color(.codeSurface), in: Capsule())
      }
      UserBubble(message: message, compact: pinned)
    }
    .padding(.vertical, 6).background(theme.color(.background))
    .onGeometryChange(for: Bool.self) {
      scrolled && $0.frame(in: .named("conversation-scroll")).minY <= 1
    } action: { _, value in
      pinned = value
    }
    .onChange(of: scrolled) { _, value in if !value { pinned = false } }
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
            } label: {
              Image(systemName: "doc.on.doc").font(.system(size: 13))
            }
            .accessibilityLabel("Copiar resposta")
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
