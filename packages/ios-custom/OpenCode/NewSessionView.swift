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
