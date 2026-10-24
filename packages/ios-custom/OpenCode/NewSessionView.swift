import OpenCodeKit
import SwiftUI

struct NewSessionView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var store: NewSessionStore
  @State private var sheet: Selector?
  @State private var presentingSelector = false
  @State private var presentation: Task<Void, Never>?
  private enum Selector: String, Identifiable {
    case project, directory, base, add
    var id: String { rawValue }
  }
  init(sessions: SessionStore, origin: NewSessionOrigin? = nil, startInChats: Bool = false) {
    _store = State(
      initialValue: NewSessionStore(sessions: sessions, origin: origin, startInChats: startInChats))
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button {
          store.draft.focused = false
          dismiss()
        } label: {
          Image(systemName: "chevron.left").appSymbol(.navigation)
            .frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: .circle)
        }.buttonStyle(.plain).accessibilityLabel("Voltar").disabled(store.draft.sending)
        Text("Nova sessão").appFont(.navigation)
        Spacer()
      }.foregroundStyle(theme.color(.textStrong)).padding(.horizontal, AppLayout.margin).padding(.vertical, 8)
      if store.chat || store.project != nil {
        GeometryReader { geometry in
          let compact = geometry.size.height < 275
          ScrollView {
            VStack(spacing: compact ? 10 : 20) {
              VStack(spacing: compact ? 8 : 13) {
                if let project = store.project {
                  ProjectAvatar(project: project, size: AppLayout.avatar, style: .message)
                } else {
                  ChatsAvatar(size: AppLayout.avatar, symbol: .action)
                }
                Text(
                  store.project.map { "No que vamos trabalhar\nem \($0.displayName)?" }
                    ?? "Sobre o que vamos\nconversar?")
                  .appFont(.title).multilineTextAlignment(.center)
                  .foregroundStyle(theme.color(.textStrong)).fixedSize(
                    horizontal: false, vertical: true
                  )
                  .frame(maxWidth: 340)
              }
              mcpChips
            }.padding(.vertical, compact ? 2 : 8).padding(.horizontal, 18)
              .frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
          }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle()).onTapGesture { store.draft.focused = false }
        }
        VStack(alignment: .leading, spacing: 10) {
          selectors
          if let error = store.loadError {
            Button {
              store.retry()
            } label: {
              Label(error + " Tentar novamente", systemImage: "arrow.clockwise")
                .appFont(.caption).foregroundStyle(theme.color(.error))
            }
          }
          FloatingVoiceHost(sessions: store.sessions)
          ConversationComposer(store: store.composer, draft: store.draft)
        }.padding(.horizontal, AppLayout.composerMargin).padding(.top, 8).padding(.bottom, 6)
      } else if !store.initialized {
        ProgressView("Carregando projetos…").frame(maxWidth: .infinity, maxHeight: .infinity)
        FloatingVoiceHost(sessions: store.sessions).padding(.horizontal, 12).padding(.bottom, 6)
      } else {
        ContentUnavailableView {
          Label("Nenhum projeto selecionado", systemImage: "folder")
        } description: {
          Text("Adicione um projeto para começar uma sessão.")
        } actions: {
          Button("Adicionar projeto") { show(.add) }.buttonStyle(.borderedProminent)
          if store.chatsAvailable {
            Button("Conversar em Chats", systemImage: "bubble.left") { store.selectChat() }
              .accessibilityIdentifier("new-empty-chats")
          }
        }
        FloatingVoiceHost(sessions: store.sessions).padding(.horizontal, 12).padding(.bottom, 6)
      }
    }
    .background(theme.color(.background)).tint(theme.color(.primary))
    .toolbar(.hidden, for: .navigationBar, .tabBar)
    .background(
      ConversationBackGesture(
        capture: { store.draft.focused = false }, appeared: {}, enabled: !store.draft.sending)
    )
    .toastOverlay(store.composer.toast)
    .environment(store.composer.toast)
    .task { await store.open() }
    .task(id: store.loadKey) { await store.reloadSelection() }
    .onAppear { store.showMCPs() }
    .onDisappear {
      store.hideMCPs()
      presentation?.cancel()
      presentingSelector = false
      store.draft.focused = false
      store.draft.focusSuppressed = false
      Task { await store.draft.persist() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { Task { await store.draft.persist() } }
    }
    .onChange(of: store.draft.focused) { _, focused in
      // The expanded composer may restore focus after a selector starts presenting.
      if focused && (sheet != nil || presentingSelector) { store.draft.focused = false }
    }
    .sheet(
      item: $sheet,
      onDismiss: {
        guard sheet == nil, !presentingSelector else { return }
        presentation = Task {
          // Let SwiftUI finish the sheet's dismissal transaction before starting a keyboard animation.
          await Task.yield()
          guard !Task.isCancelled, sheet == nil, !presentingSelector,
            store.sessions.conversationPath.last?.newSession == true
          else { return }
          store.draft.focusSuppressed = false
          store.draft.focused = true
          // Do not overlap keyboard restoration with the interactive sheet's finishing animation.
          UIView.performWithoutAnimation { store.draft.input?.becomeFirstResponder() }
        }
      }
    ) { selector in
      Group {
        switch selector {
        case .project:
          NewSessionProjectSheet(store: store) {
            sheet = .add
          }
        case .directory: NewSessionDirectorySheet(store: store)
        case .base: NewSessionBaseSheet(store: store)
        case .add:
          AddProjectPicker(store: store.sessions) { project in await store.selectProject(project) }
        }
      }.sessionAlertOverlay()
    }
  }
  private func show(_ selector: Selector) {
    guard !presentingSelector else { return }
    presentation?.cancel()
    presentingSelector = true
    store.draft.focusSuppressed = true
    store.draft.focused = false
    presentation = Task {
      // Presenting during the hide animation can make UIKit retain the composer's keyboard.
      await store.draft.input?.dismissKeyboard()
      guard !Task.isCancelled else { return }
      sheet = selector
      presentingSelector = false
    }
  }
  private var selectors: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 20) {
        Button {
          show(.project)
        } label: {
          HStack(spacing: 7) {
            if let project = store.project {
              ProjectAvatar(project: project, size: 23, style: .micro)
            } else {
              ChatsAvatar(size: 23, symbol: .inline)
            }
            Text(store.project?.displayName ?? "Chats").lineLimit(1)
            chevron
          }
        }.accessibilityLabel("Projeto: \(store.project?.displayName ?? "Chats")")
          .accessibilityIdentifier("new-project")
        if !store.chat && store.destination != .create { directorySelector }
        Spacer(minLength: 0)
      }
      if !store.chat && store.destination == .create {
        HStack(spacing: 18) {
          directorySelector
          Button {
            show(.base)
          } label: {
            HStack(spacing: 7) {
              GitBranchIcon().foregroundStyle(theme.color(.icon))
              Text("a partir de \(store.baseBranch ?? "HEAD")").lineLimit(1)
              chevron
            }
          }.accessibilityIdentifier("new-base")
        }
      }
    }.appFont(.secondary).foregroundStyle(theme.color(.text)).buttonStyle(.plain)
      .padding(.horizontal, 6).disabled(store.draft.sending || store.loading || presentingSelector)
  }
  private var directorySelector: some View {
    Button {
      show(.directory)
    } label: {
      HStack(spacing: 7) {
        Group {
          if store.destination == .create { Image(systemName: "plus") } else { GitBranchIcon() }
        }.foregroundStyle(theme.color(.icon))
        Text(store.git || store.loading ? store.directoryLabel : "Sem Git").lineLimit(1)
        chevron
      }
    }.accessibilityLabel("Diretório: \(store.directoryLabel)").accessibilityIdentifier(
      "new-directory")
  }
  private var chevron: some View {
    Image(systemName: "chevron.down").appSymbol(.disclosure).foregroundStyle(
      theme.color(.textSecondary))
  }
  private var mcpChips: some View {
    VStack(spacing: 7) {
      if store.mcpLoading {
        ProgressView("Carregando MCPs…").appFont(.caption).tint(theme.color(.textSecondary))
      } else if store.mcpError {
        Button {
          store.retry()
        } label: {
          Text("Não foi possível carregar MCPs · Tentar novamente").appFont(.caption)
        }.foregroundStyle(theme.color(.textSecondary))
      } else if store.chips.isEmpty {
        Text("Nenhum MCP configurado").appFont(.caption).foregroundStyle(theme.color(.textSecondary))
      } else {
        MCPFlowLayout(spacing: 7) {
          ForEach(store.chips) { server in
            MCPChip(server: server, preview: store.preview, chat: store.chat) {
              store.toggle(server)
            }
          }
        }.disabled(store.draft.sending)
      }
      if store.preview {
        Text(store.chat ? "Vale quando o chat for criado" : "Vale quando a worktree for criada")
          .appFont(.footnote).foregroundStyle(theme.color(.textSecondary))
      }
    }
  }
}

struct ProjectAvatar: View {
  @Environment(\.appTheme) private var theme
  let project: Project
  let size: CGFloat
  let style: AppTextStyle
  var body: some View {
    let colors = theme.avatar(SessionList.avatarColor(project, fallback: project.id))
    Text(SessionList.monogram(project.displayName)).appFont(style, weight: .medium)
      .minimumScaleFactor(0.6).lineLimit(1)
      .foregroundStyle(colors.text).frame(width: size, height: size)
    .background(colors.background, in: Circle()).accessibilityHidden(true)
  }
}

/// The managed chats destination, drawn like the web's speech-bubble Chats item.
struct ChatsAvatar: View {
  @Environment(\.appTheme) private var theme
  let size: CGFloat
  let symbol: AppSymbolSize
  var body: some View {
    Image(systemName: "bubble.left").appSymbol(symbol)
      .foregroundStyle(theme.color(.icon)).frame(width: size, height: size)
      .background(theme.color(.highlight), in: Circle()).accessibilityHidden(true)
  }
}

struct GitBranchIcon: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 4, y: 5))
      path.addLine(to: CGPoint(x: 4, y: 13))
      path.move(to: CGPoint(x: 12, y: 5))
      path.addQuadCurve(to: CGPoint(x: 4, y: 10), control: CGPoint(x: 12, y: 10))
      for center in [CGPoint(x: 4, y: 3), CGPoint(x: 4, y: 15), CGPoint(x: 12, y: 3)] {
        path.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
      }
      context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }.frame(width: 16, height: 18).accessibilityHidden(true)
  }
}

struct MCPChip: View {
  @Environment(\.appTheme) private var theme
  let server: MCPServer
  let preview: Bool
  var chat = false
  let toggle: () -> Void
  @State private var pulse = false
  private var disabled: Bool { server.status.status == .disabled }
  private var pending: Bool { server.status.status == .pending }
  private var dotRole: ThemeRole {
    switch server.status.status {
    case .connected: .success
    case .failed: .error
    case .needsAuth: .warning
    default: .textWeak
    }
  }
  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 7) {
        Circle().fill(theme.color(dotRole)).frame(width: 7, height: 7)
          .opacity(pending && pulse ? 0.3 : 1)
        Text(server.name).appFont(.caption).lineLimit(1).frame(maxWidth: 184)
          .foregroundStyle(theme.color(disabled ? .textWeak : .text))
      }.padding(.horizontal, 12).frame(minHeight: 32)
        .overlay {
          Capsule().strokeBorder(
            theme.color(.border), style: StrokeStyle(lineWidth: 0.8, dash: disabled ? [4, 3] : []))
        }
    }.buttonStyle(.plain).disabled(pending || server.status.status == .unknown)
      .opacity(pending ? 0.6 : 1)
      .accessibilityRepresentation {
        Toggle(isOn: Binding(get: { server.enabled }, set: { _ in toggle() })) {
          Text(server.name)
        }.disabled(pending || server.status.status == .unknown)
          .accessibilityHint(
            preview
              ? (chat
                ? "Prévia. Vale quando o chat for criado."
                : "Prévia. Vale quando a worktree for criada.")
              : "Altera o MCP para todas as sessões deste diretório."
          )
          .accessibilityValue(server.status.status.label)
          .accessibilityIdentifier("mcp-" + server.name)
      }
      .task(id: pending) {
        guard pending else {
          pulse = false
          return
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
      }
  }
}

struct MCPFlowLayout: Layout {
  let spacing: CGFloat
  var centered = true
  private func rows(_ subviews: Subviews, width: CGFloat) -> [[LayoutSubview]] {
    var rows: [[LayoutSubview]] = [[]]
    var used: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if used > 0 && used + spacing + size.width > width {
        rows.append([])
        used = 0
      }
      rows[rows.count - 1].append(view)
      used += size.width + (used > 0 ? spacing : 0)
    }
    return rows
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 360
    let heights = rows(subviews, width: width).map { row in
      row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    }
    return CGSize(
      width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(subviews, width: bounds.width) {
      let sizes = row.map { $0.sizeThatFits(.unspecified) }
      let width = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
      var x = centered ? bounds.midX - width / 2 : bounds.minX
      for (index, view) in row.enumerated() {
        view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[index]))
        x += sizes[index].width + spacing
      }
      y += (sizes.map(\.height).max() ?? 0) + spacing
    }
  }
}
