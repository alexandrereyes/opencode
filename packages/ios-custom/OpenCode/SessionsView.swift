import OpenCodeKit
import SwiftUI

struct SessionsView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    let directory: String
    let name: String
    let index: Int?
    var id: String { directory }
  }

  var body: some View {
    NavigationStack(path: $store.conversationPath) {
      List {
        VStack(spacing: 16) {
          usage
          chips
        }
        .padding(.horizontal, AppLayout.margin)
        .padding(.top, 9)
        .padding(.bottom, 16)
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

        if !store.attention.isEmpty {
          attentionCard
            .listRowInsets(EdgeInsets(top: 0, leading: AppLayout.margin, bottom: 16, trailing: AppLayout.margin))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.color(.background))
        }

        Button {
          showArchived = true
        } label: {
          HStack(spacing: AppLayout.avatarGap) {
            Image(systemName: "archivebox").appSymbol(.header).frame(width: AppLayout.avatar)
            Text("Arquivadas").appFont(.heading, weight: .semibold)
            Spacer()
            Text("\(store.archived.count)").appFont(.secondary).monospacedDigit()
          }
          .foregroundStyle(theme.color(.textSecondary))
          .padding(.vertical, 14)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: AppLayout.margin, bottom: 0, trailing: AppLayout.margin))
        .listRowSeparatorTint(theme.color(.border))
        .listRowBackground(theme.color(.background))
        .alignmentGuide(.listRowSeparatorLeading) { _ in AppLayout.rowTextInset }

        ForEach(store.recent) { row in
          Button {
            store.conversationPath.append(.init(id: row.id))
          } label: {
            SessionRowView(
              row: row, preview: store.previews[row.id] ?? SessionPreview(),
              directory: store.directoryLabel(row.session))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("session-row-" + row.id)
          .listRowInsets(EdgeInsets(top: 14, leading: AppLayout.margin, bottom: 14, trailing: AppLayout.margin))
          .listRowSeparatorTint(theme.color(.border))
          .listRowBackground(theme.color(.background))
          .alignmentGuide(.listRowSeparatorLeading) { _ in AppLayout.rowTextInset }
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
          .onAppear { store.show(row.session) }
          .onDisappear { store.hide(row.session) }
        }

        if store.entries.isEmpty && store.loading {
          HStack {
            Spacer()
            ProgressView("Carregando sessões…")
            Spacer()
          }
          .padding(.vertical, 30).listRowSeparator(.hidden)
        } else if store.recent.isEmpty && store.attention.isEmpty && !store.loading {
          ContentUnavailableView(
            "Nenhuma sessão", systemImage: "bubble.left.and.bubble.right",
            description: Text("As sessões aparecerão aqui quando estiverem disponíveis.")
          )
          .foregroundStyle(theme.color(.textSecondary))
          .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
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
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("Selecionar sessões", systemImage: "checkmark.circle") {}.disabled(true)
            Button("Marcar todas como lidas", systemImage: "envelope.open") {
              Task { await store.markAllRead() }
            }
            .disabled(store.busy.contains("read-all"))
            Button("Atualizar", systemImage: "arrow.clockwise") {
              Task { await store.quota.refresh() }
              Task { await store.reload() }
            }
            Button("Configurações", systemImage: "gearshape") {}.disabled(true)
          } label: {
            Image(systemName: "ellipsis").appSymbol(.header).foregroundStyle(theme.color(.textStrong))
          }
          .accessibilityLabel("Mais opções")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            if let floatingVoice { floatingVoice.toggle(voice, sessions: store) }
            else { voice?.toggle(sessions: store) }
          } label: {
            Image(systemName: "waveform").appSymbol(.header).foregroundStyle(
              theme.color(floatingVoice?.visible(voice) == true ? .primary : .textStrong))
          }
          .accessibilityLabel(floatingVoice?.visible(voice) == true ? "Encerrar conversa por voz" : "Conversar por voz")
          .accessibilityIdentifier("voice-start")
          Button {
            // Sessões starts new work in Chats; projects and worktrees remain one tap away.
            store.conversationPath.append(
              .init(id: "draft_" + UUID().uuidString, newSession: true, startInChats: true))
          } label: {
            Image(systemName: "plus").appSymbol(.header).foregroundStyle(theme.color(.onPrimary))
          }
          .buttonStyle(.glassProminent)
          .tint(theme.color(.primary))
          .accessibilityLabel("Nova sessão")
          .disabled(store.preferences == nil)
        }
      }
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
        projectAction?.index == nil ? "Remover dos filtros?" : "Reordenar repositório?",
        isPresented: Binding(
          get: { projectAction != nil }, set: { if !$0 { projectAction = nil } }),
        titleVisibility: .visible
      ) {
        if let action = projectAction {
          Button(
            action.index == nil ? "Remover dos filtros" : "Confirmar nova posição",
            role: action.index == nil ? .destructive : nil
          ) {
            Task {
              await store.mutate(
                action.index.map { .move(directory: action.directory, toIndex: $0) }
                  ?? .close(directory: action.directory))
            }
            projectAction = nil
          }
        }
        Button("Cancelar", role: .cancel) { projectAction = nil }
      } message: {
        Text("Isso altera apenas os filtros. O repositório e suas sessões não serão excluídos.")
      }
    }
    .sessionRowTimeline(active: store.selectedTab == 3 && !store.conversationOpen && !showArchived)
  }

  private var usage: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(spacing: 20))
    return layout {
      ForEach(store.quota.providers) { provider in
        Button { proxyProvider = provider } label: {
          UsageMeter(summary: store.quota.summary(provider),
                     name: store.quota.selected(provider).map { provider.title + " · " + $0.name } ?? provider.title)
        }.buttonStyle(.plain).accessibilityIdentifier("proxy-strip-" + provider.rawValue)
          .accessibilityHint("Ver contas, limites e renovações do LLM proxy")
      }
    }
  }

  private var chips: some View {
    SessionChips(store: store) { directory, name, index in
      projectAction = ProjectAction(directory: directory, name: name, index: index)
    } add: {
      showProjects = true
    }
  }

  private var attentionCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Precisa de você · \(store.attention.count)")
        .appFont(.preview, weight: .semibold).monospacedDigit()
        .foregroundStyle(theme.color(.textSecondary))
        .padding(.bottom, 12)
      ForEach(Array(store.attention.enumerated()), id: \.element.id) { index, row in
        if index > 0 {
          Rectangle().fill(theme.color(.border)).frame(height: 1 / displayScale)
            .padding(.leading, AppLayout.rowTextInset).padding(.vertical, 12)
        }
        VStack(alignment: .trailing, spacing: 12) {
          HStack(spacing: AppLayout.avatarGap) {
            SessionAvatar(row: row, size: AppLayout.avatar)
            VStack(alignment: .leading, spacing: 3) {
              Button {
                store.conversationPath.append(.init(id: row.id))
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(row.session.displayTitle).appFont(.heading, weight: row.unread ? .bold : .regular)
                  .foregroundStyle(theme.color(.textStrong)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  SessionRowTime(at: row.interactionAt, unread: row.unread).layoutPriority(1)
                }
              }.buttonStyle(.plain)
              SessionDirectoryLine(label: store.directoryLabel(row.session))
              Text(
                row.state == .permission
                  ? store.permission(row)?.preview ?? "Permissão pendente" : store.question(row)
              )
              .appFont(.preview).foregroundStyle(
                theme.color(row.state == .permission ? .error : .info)
              )
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          if row.state == .permission {
            HStack(spacing: 8) {
              Button("Negar") { Task { await store.reply(row, allow: false) } }
                .appFont(.secondary, weight: .medium)
                .foregroundStyle(theme.color(.text))
                .padding(.horizontal, 16).frame(minHeight: 34)
                .contentShape(Capsule())
                .overlay { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
                .buttonStyle(.plain)
              Button("Permitir") { Task { await store.reply(row, allow: true) } }
                .padding(.horizontal, 16).frame(minHeight: 34)
                .background(theme.color(.filledButton), in: Capsule()).buttonStyle(.plain)
                .foregroundStyle(theme.color(.onFilledButton))
            }
            .disabled(store.busy.contains(row.id) || store.permission(row) == nil)
          } else {
            Button("Responder") { store.conversationPath.append(.init(id: row.id)) }
              .padding(.horizontal, 16).frame(minHeight: 34)
              .background(theme.color(.infoFill), in: Capsule()).buttonStyle(.plain)
              .foregroundStyle(theme.color(.onInfo))
          }
        }
        .appFont(.secondary, weight: .medium)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .contextMenu { rowActions(row) }
      }
    }
    .padding(16)
    .background(theme.color(.surface).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.border), lineWidth: 1 / displayScale)
    }
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

/// Its own view so preview/streaming updates of the list never re-evaluate the chips.
private struct SessionChips: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let store: SessionStore
  let action: (_ directory: String, _ name: String, _ index: Int?) -> Void
  let add: () -> Void
  /// The displayed order changes only while the strip is idle, so chips never move under a finger.
  @State private var shown: [String] = []
  @State private var scrolling = false

  private var manual: [String] {
    (store.chatRoot == nil ? [] : [SessionStore.chatsSelection]) + store.selectedProjects.map(\.project.id)
  }
  var body: some View {
    let groups = SessionList.chipGroups(store.rows, manual: manual, chats: SessionStore.chatsSelection)
    let desired = groups.map(\.key)
    let order = shown.filter(desired.contains) + desired.filter { !shown.contains($0) }
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          Menu {
            ForEach(SessionFilter.allCases.filter { $0 != .all }) { filter in
              Button(filter.rawValue) { store.filter = filter }
            }
          } label: {
            Chip(
              title: store.filter.rawValue,
              selected: store.selectedProject == nil || store.filter != .all)
          } primaryAction: {
            store.filter = .all
            store.selectedProject = nil
          }
          .accessibilityHint("Mantenha pressionado para filtrar por estado")
          ForEach(order, id: \.self) { key in
            if let group = groups.first(where: { $0.key == key }) { chip(group).id(key) }
          }
          Button(action: add) {
            Chip(title: "+", selected: false)
          }
          .accessibilityLabel("Adicionar repositório aos filtros")
        }
      }
      .scrollIndicators(.hidden)
      .buttonStyle(.plain)
      .onScrollPhaseChange { _, phase in
        scrolling = phase != .idle
        if !scrolling { apply(desired, proxy) }
      }
      .onAppear {
        shown = desired
        // Reordering while a conversation covered the strip cannot scroll it; reveal the filter on return.
        reveal(proxy)
      }
      .onChange(of: desired) { _, value in if !scrolling { apply(value, proxy) } }
    }
  }
  private func apply(_ desired: [String], _ proxy: ScrollViewProxy) {
    guard shown != desired else { return }
    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { shown = desired }
    reveal(proxy)
  }
  /// Keeps the active filter on screen once the new positions are laid out (after the reorder animation).
  private func reveal(_ proxy: ScrollViewProxy) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      guard !scrolling, let selected = store.selectedProject, shown.contains(selected) else { return }
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { proxy.scrollTo(selected) }
    }
  }
  @ViewBuilder private func chip(_ group: ChipGroup) -> some View {
    if group.key == SessionStore.chatsSelection {
      Button {
        store.selectedProject = store.chatsSelected ? nil : SessionStore.chatsSelection
      } label: {
        Chip(
          title: "Chats", selected: store.chatsSelected, running: group.running,
          count: group.requests, unread: group.unread, symbol: "bubble.left")
      }
      .accessibilityLabel(group.unread ? "Chats, com não lidas" : "Chats")
      .accessibilityIdentifier("filter-chats")
    } else if let index = store.selectedProjects.firstIndex(where: { $0.project.id == group.key }) {
      let selected = store.selectedProjects[index]
      let name = selected.project.displayName
      // Antes/depois refer to the saved manual order, which unread chips may visually bypass.
      Menu {
        Button("Remover dos filtros", systemImage: "minus.circle", role: .destructive) {
          action(selected.directory, name, nil)
        }
        if index > 0 {
          Button("Mover para antes", systemImage: "arrow.left") {
            action(selected.directory, name, index - 1)
          }
        }
        if index + 1 < store.selectedProjects.count {
          Button("Mover para depois", systemImage: "arrow.right") {
            action(selected.directory, name, index + 1)
          }
        }
      } label: {
        Chip(
          title: name, selected: store.selectedProject == group.key, running: group.running,
          count: group.requests, unread: group.unread)
      } primaryAction: {
        store.selectedProject = store.selectedProject == group.key ? nil : group.key
      }
      .accessibilityLabel(group.unread ? name + ", com não lidas" : name)
      .accessibilityIdentifier("filter-project-" + name)
    }
  }
}

private struct Chip: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @ScaledMetric(relativeTo: .subheadline) private var minimumHeight = 36.0
  let title: String
  let selected: Bool
  var running = false
  var count = 0
  /// The list rows' orange unread dot, as a corner badge that coexists with the running arc.
  var unread = false
  var symbol: String?

  var body: some View {
    HStack(spacing: 8) {
      if running { RunningArc(size: 9, filled: true) }
      if let symbol { Image(systemName: symbol).appSymbol(.inline) }
      Text(title).appFont(.secondary, weight: selected ? .semibold : .regular).lineLimit(1)
      if count > 0 {
        Text("\(count)").appFont(.footnote, weight: .medium).monospacedDigit().padding(.horizontal, 5).padding(
          .vertical, 1
        ).background(theme.color(.highlight), in: Capsule())
      }
    }
    .foregroundStyle(theme.color(selected ? .textAccent : .text))
    .padding(.horizontal, 16).frame(minHeight: minimumHeight)
    .background(
      theme.color(selected ? .primary : .surface).opacity(selected ? 0.08 : 1), in: Capsule()
    )
    .overlay {
      Capsule().strokeBorder(theme.color(selected ? .primary : .controlBorder), lineWidth: 1 / displayScale)
    }
    .overlay(alignment: .topTrailing) {
      if unread {
        Circle().fill(theme.color(.primary)).frame(width: 8, height: 8)
          .overlay { Circle().strokeBorder(theme.color(.background), lineWidth: 1.5) }
          .offset(x: -8, y: 3).accessibilityHidden(true)
      }
    }
  }
}

private struct UsageMeter: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let summary: Subscriptions.Summary?
  let name: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Circle().fill(theme.color(summary?.ready == true ? .success : .warning)).frame(
          width: 8, height: 8)
        Text(summary?.label(name) ?? "\(name) — · —").appFont(.secondary).monospacedDigit().foregroundStyle(
          theme.color(.text)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).truncationMode(.middle)
      }
      GeometryReader { geometry in
        Capsule().fill(theme.color(.highlight))
          .overlay(alignment: .leading) {
            Capsule().fill(theme.color(.success))
              .frame(width: geometry.size.width * min(1, max(0, (summary?.remaining ?? 0) / 100)))
          }
      }.frame(height: 4)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}
