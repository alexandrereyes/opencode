import OpenCodeKit
import SwiftUI

struct SessionsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.voiceController) private var voice
  @Environment(\.floatingVoice) private var floatingVoice
  @Bindable var store: SessionStore
  @State private var archiveCandidate: SessionRow?
  @State private var renameCandidate: SessionRow?
  @State private var deleteCandidate: Session?
  @State private var projectAction: ProjectAction?
  @State private var showProjects = false
  @State private var showArchived = false
  @State private var appliedLaunch = false
  @State private var proxyProvider: SubscriptionProvider?

  private struct ProjectAction: Identifiable {
    let name: String
    let intent: PreferenceIntent
    var id: String { name }
    var removes: Bool { if case .close = intent { true } else { false } }
  }

  var body: some View {
    NavigationStack(path: $store.conversationPath) {
      List {
        VStack(spacing: 16) {
          SessionQuotaRings(quota: store.quota) { proxyProvider = $0 }
          SessionChips(store: store) { name, intent in
            projectAction = ProjectAction(name: name, intent: intent)
          } add: {
            showProjects = true
          }
        }
        .padding(.horizontal, AppLayout.margin)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.color(.background))
        if let notice = store.notice {
          ConversationNoticeView(notice: notice) { Task { await store.reload() } }
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        } else if let error = store.error {
          HStack(alignment: .top) {
            Image(systemName: "wifi.exclamationmark")
            Text(error).appFont(.caption)
            Spacer()
            Button("Tentar novamente") { Task { await store.reload() } }.appFont(.caption)
          }
          .foregroundStyle(theme.color(.error))
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
        }

        SessionColumnSections(store: store) { row in
          store.conversationPath.append(.init(id: row.id))
        } archived: {
          showArchived = true
        } decorate: { row, content in
          content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              // A destructive swipe role removes the row before confirmation in SwiftUI.
              Button {
                Haptics.play(.warning)
                deleteCandidate = row.session
              } label: {
                Label("Excluir", systemImage: "trash")
              }.tint(theme.color(.error))
              Button {
                renameCandidate = row
              } label: {
                Label("Renomear", systemImage: "pencil")
              }.tint(theme.color(.info))
              Button {
                archiveCandidate = row
              } label: {
                Label("Arquivar", systemImage: "archivebox")
              }
              .tint(theme.color(.primary))
              Button {
                Task { await store.mute(row) }
              } label: {
                Label(
                  row.muted ? "Reativar" : "Silenciar",
                  systemImage: row.muted ? "bell" : "bell.slash")
              }.tint(theme.color(.icon))
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
              if row.unread {
                Button {
                  Task { await store.markRead(row.session) }
                } label: {
                  Label("Marcar como lida", systemImage: "envelope.open")
                }
                .tint(theme.color(.primary))
              }
              Button {
                Task { await store.pin(row) }
              } label: {
                Label(
                  row.pinned ? "Desafixar" : "Fixar", systemImage: row.pinned ? "pin.slash" : "pin")
              }.tint(theme.color(.info))
            }
            .contextMenu { rowActions(row) }
            .disabled(store.busy.contains(row.id))
        }
      }
      .listStyle(.plain)
      // The shared column header replaces the navigation bar's large title and toolbar.
      .safeAreaBar(edge: .top) {
        SessionColumnHeader(
          voiceActive: floatingVoice?.visible(voice) == true,
          voice: {
            if let floatingVoice { floatingVoice.toggle(voice, sessions: store) }
            else { voice?.toggle(sessions: store) }
          },
          settings: settings,
          newSession: {
            // Sessões starts new work in Chats; projects and worktrees remain one tap away.
            store.conversationPath.append(
              .init(id: "draft_" + UUID().uuidString, newSession: true, startInChats: true))
          },
          newSessionDisabled: store.preferences == nil)
      }
      .environment(\.defaultMinListRowHeight, 0)
      .scrollContentBackground(.hidden)
      .background(theme.color(.background))
      .background(ConversationRenameAlert(
        isPresented: Binding(get: { renameCandidate != nil }, set: { if !$0 { renameCandidate = nil } }),
        title: renameCandidate?.session.title ?? "", theme: theme
      ) { [row = renameCandidate] title in
        if let row { Task { await store.rename(row, title: title) } }
      })
      .scrollEdgeEffectStyle(.soft, for: .top)
      .scrollEdgeEffectStyle(.hard, for: .bottom)
      .floatingVoiceInset(sessions: store)
      .refreshable {
        async let sessions: Void = store.reload()
        await store.quota.refresh()
        await sessions
      }
      .navigationTitle("Sessões")
      .toolbarVisibility(.hidden, for: .navigationBar)
      .navigationDestination(for: SessionStore.ConversationRoute.self) { route in
        if route.master {
          MasterSessionView(sessions: store)
        } else if route.agents {
          if let conversation = store.liveConversation(route.id) {
            ConversationAgentsView(store: conversation, sessions: store)
          } else {
            Text("Conversa indisponível.").foregroundStyle(theme.color(.textSecondary))
          }
        } else if route.newSession {
          NewSessionView(sessions: store, origin: route.origin, startInChats: route.startInChats)
            .id(route.id)
        } else {
          ConversationView(id: route.id, sessions: store, parentOnStack: route.parent, toolID: route.tool)
            .toastOverlay(store.toast)
        }
      }
      .toastOverlay(store.toast)
      .task {
        guard !appliedLaunch, store.acceptsLaunchSession else { return }
        appliedLaunch = true
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-OpenCodeOpenSession"),
          arguments.indices.contains(index + 1)
        {
          if let session = try? await store.client.session(arguments[index + 1]), !Task.isCancelled {
            store.conversationPath.append(.init(id: session.id))
          }
        }
        if let index = arguments.firstIndex(of: "-OpenCodeOpenResource"), arguments.indices.contains(index + 1),
          let resource = try? await store.client.resource(arguments[index + 1]), !Task.isCancelled
        {
          store.openResource = resource
        }
      }
      .sheet(isPresented: $showProjects) { AddProjectPicker(store: store).sessionAlertOverlay() }
      .sessionDeleteConfirmation($deleteCandidate, store: store)
      .sheet(isPresented: $showArchived) { ArchivedSessionsView(store: store).sessionAlertOverlay() }
      .sheet(item: $proxyProvider) { provider in
        SubscriptionDetailSheet(store: store.quota, initialProvider: provider).sessionAlertOverlay()
      }
      .confirmationDialog(
        "Arquivar sessão?",
        isPresented: Binding(
          get: { archiveCandidate != nil }, set: { if !$0 { archiveCandidate = nil } }),
        titleVisibility: .visible
      ) {
        if let row = archiveCandidate {
          Button("Arquivar", role: .destructive) {
            Task { await store.archive(row) }
            archiveCandidate = nil
          }
        }
        Button("Cancelar", role: .cancel) { archiveCandidate = nil }
      } message: {
        Text(
          "A sessão sairá de Recentes e ficará na lista de arquivadas. Não há opção de desarquivar nesta versão."
        )
      }
      .confirmationDialog(
        projectAction?.removes == true
          ? "Remover dos filtros?" : projectAction?.name == "Chats" ? "Reordenar Chats?" : "Reordenar repositório?",
        isPresented: Binding(
          get: { projectAction != nil }, set: { if !$0 { projectAction = nil } }),
        titleVisibility: .visible
      ) {
        if let action = projectAction {
          Button(
            action.removes ? "Remover dos filtros" : "Confirmar nova posição",
            role: action.removes ? .destructive : nil
          ) {
            Task { await store.mutate(action.intent) }
            projectAction = nil
          }
        }
        Button("Cancelar", role: .cancel) { projectAction = nil }
      } message: {
        Text(
          projectAction?.name == "Chats"
            ? "Isso altera apenas a ordem dos filtros."
            : "Isso altera apenas os filtros. O repositório e suas sessões não serão excluídos.")
      }
    }
    .sessionRowTimeline(active: store.selectedTab == 3 && !store.conversationOpen && !showArchived)
  }

  /// Settings stay in Você on iOS; only the Mac passes this action. A DEBUG fixture renders that variant.
  private var settings: (() -> Void)? {
    #if DEBUG
    if ScreenCatalogFixture.settingsButton { return { store.selectedTab = 4 } }
    #endif
    return nil
  }

  @ViewBuilder private func rowActions(_ row: SessionRow) -> some View {
    Button("Abrir sessão", systemImage: "bubble.left") { store.conversationPath.append(.init(id: row.id)) }
    Button("Renomear", systemImage: "pencil") { renameCandidate = row }
    Button(row.pinned ? "Desafixar" : "Fixar", systemImage: row.pinned ? "pin.slash" : "pin") {
      Task { await store.pin(row) }
    }
    Button(row.muted ? "Reativar" : "Silenciar", systemImage: row.muted ? "bell" : "bell.slash") {
      Task { await store.mute(row) }
    }
    if row.unread {
      Button("Marcar como lida", systemImage: "envelope.open") {
        Task { await store.markRead(row.session) }
      }
    }
    Button("Excluir sessão", systemImage: "trash", role: .destructive) {
      Haptics.play(.warning)
      deleteCandidate = row.session
    }
  }
}
