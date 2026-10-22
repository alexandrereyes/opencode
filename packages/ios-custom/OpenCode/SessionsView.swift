import OpenCodeKit
import SwiftUI

struct SessionsView: View {
  @Environment(\.appTheme) private var theme
  @Bindable var store: SessionStore
  @State private var archiveCandidate: SessionRow?
  @State private var projectAction: ProjectAction?
  @State private var showProjects = false
  @State private var showArchived = false
  @State private var moreSession: SessionRow?
  @State private var appliedLaunch = false

  private struct ProjectAction: Identifiable {
    let directory: String
    let name: String
    let index: Int?
    var id: String { directory }
  }

  var body: some View {
    NavigationStack(path: $store.conversationPath) {
      List {
        VStack(spacing: 13) {
          usage
          chips
        }
        .padding(.horizontal, 16)
        .padding(.top, 1)
        .padding(.bottom, 10)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.color(.background))
        if let notice = store.notice {
          ConversationNoticeView(notice: notice) { Task { await store.reload() } }
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
        } else if let error = store.error {
          HStack(alignment: .top) {
            Image(systemName: "wifi.exclamationmark")
            Text(error).font(.footnote)
            Spacer()
            Button("Tentar novamente") { Task { await store.reload() } }.font(.footnote)
          }
          .foregroundStyle(theme.color(.error))
          .listRowSeparator(.hidden)
          .listRowBackground(theme.color(.background))
        }

        if !store.attention.isEmpty {
          attentionCard
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 9, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.color(.background))
        }

        Button {
          showArchived = true
        } label: {
          HStack(spacing: 16) {
            Image(systemName: "archivebox").font(.system(size: 21)).frame(width: 44)
            Text("Arquivadas").font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("\(store.archived.count)").font(.system(size: 14)).monospacedDigit()
          }
          .foregroundStyle(theme.color(.textSecondary))
          .padding(.vertical, 8)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 19))
        .listRowSeparatorTint(theme.color(.border))
        .listRowBackground(theme.color(.background))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }

        ForEach(store.recent) { row in
          Button {
            store.conversationPath.append(.init(id: row.id))
          } label: {
            SessionRowView(
              row: row, preview: store.previews[row.id] ?? SessionPreview(),
              branch: store.branch(row.session))
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 18))
          .listRowSeparatorTint(theme.color(.border))
          .listRowBackground(theme.color(.background))
          .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
              moreSession = row
            } label: {
              Label("Mais", systemImage: "ellipsis")
            }
            .tint(theme.color(.textWeak))
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
      .scrollEdgeEffectStyle(.soft, for: .top)
      .scrollEdgeEffectStyle(.hard, for: .bottom)
      .refreshable { await store.reload() }
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
            Button("Atualizar", systemImage: "arrow.clockwise") { Task { await store.reload() } }
            Button("Configurações", systemImage: "gearshape") {}.disabled(true)
          } label: {
            Image(systemName: "ellipsis").foregroundStyle(theme.color(.textStrong))
          }
          .accessibilityLabel("Mais opções")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
          } label: {
            Image(systemName: "waveform").foregroundStyle(theme.color(.textStrong))
          }
          .accessibilityLabel("Conversar por voz").accessibilityHint("Em construção")
          Button {
            store.conversationPath.append(.init(id: "draft_" + UUID().uuidString, newSession: true))
          } label: {
            Image(systemName: "plus").foregroundStyle(theme.color(.onPrimary))
          }
          .buttonStyle(.glassProminent)
          .tint(theme.color(.primary))
          .accessibilityLabel("Nova sessão")
          .disabled(store.preferences == nil)
        }
      }
      .navigationDestination(for: SessionStore.ConversationRoute.self) { route in
        if route.newSession {
          NewSessionView(sessions: store)
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
      }
      .sheet(isPresented: $showProjects) { AddProjectPicker(store: store).sessionAlertOverlay() }
      .sheet(isPresented: $showArchived) { ArchivedSessionsView(store: store).sessionAlertOverlay() }
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
      .confirmationDialog(
        moreSession?.session.displayTitle ?? "Sessão",
        isPresented: Binding(get: { moreSession != nil }, set: { if !$0 { moreSession = nil } }),
        titleVisibility: .visible
      ) {
        if let row = moreSession { rowActions(row) }
        Button("Cancelar", role: .cancel) { moreSession = nil }
      }
    }
  }

  private var usage: some View {
    HStack(spacing: 20) {
      UsageMeter(
        summary: store.subscriptions?.summary(anthropic: false), name: "Codex")
      UsageMeter(
        summary: store.subscriptions?.summary(anthropic: true), name: "Claude")
    }
  }

  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 7) {
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
        ForEach(Array(store.selectedProjects.enumerated()), id: \.element.directory) {
          index, selected in
          let rows = store.rows.filter { $0.project?.id == selected.project.id }
          Menu {
            Button("Remover dos filtros", systemImage: "minus.circle", role: .destructive) {
              projectAction = ProjectAction(
                directory: selected.directory, name: selected.project.displayName, index: nil)
            }
            if index > 0 {
              Button("Mover para antes", systemImage: "arrow.left") {
                projectAction = ProjectAction(
                  directory: selected.directory, name: selected.project.displayName,
                  index: index - 1)
              }
            }
            if index + 1 < store.selectedProjects.count {
              Button("Mover para depois", systemImage: "arrow.right") {
                projectAction = ProjectAction(
                  directory: selected.directory, name: selected.project.displayName,
                  index: index + 1)
              }
            }
          } label: {
            Chip(
              title: selected.project.displayName,
              selected: store.selectedProject == selected.project.id,
              running: rows.contains { $0.state == .running },
              count: rows.filter { $0.requestCount > 0 }.count)
          } primaryAction: {
            store.selectedProject =
              store.selectedProject == selected.project.id ? nil : selected.project.id
          }
        }
        Button {
          showProjects = true
        } label: {
          Chip(title: "+", selected: false)
        }
        .accessibilityLabel("Adicionar repositório aos filtros")
      }
    }
    .scrollIndicators(.hidden)
    .buttonStyle(.plain)
  }

  private var attentionCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Precisa de você · \(store.attention.count)")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.color(.textSecondary))
        .padding(.bottom, 9)
      ForEach(Array(store.attention.enumerated()), id: \.element.id) { index, row in
        if index > 0 {
          Rectangle().fill(theme.color(.border)).frame(height: 0.5).padding(.vertical, 9)
        }
        HStack(spacing: 10) {
          SessionAvatar(row: row, size: 42)
          VStack(alignment: .leading, spacing: 3) {
            Button {
              store.conversationPath.append(.init(id: row.id))
            } label: {
              Text(row.session.displayTitle).font(
                .system(size: 15, weight: row.unread ? .semibold : .regular)
              )
              .foregroundStyle(theme.color(.textStrong)).lineLimit(1)
            }.buttonStyle(.plain)
            Text(store.branch(row.session)).font(.system(size: 12)).foregroundStyle(
              theme.color(.textSecondary)
            ).lineLimit(1)
            Text(
              row.state == .permission
                ? store.permission(row)?.preview ?? "Permissão pendente" : store.question(row)
            )
            .font(.system(size: 12.5)).foregroundStyle(
              theme.color(row.state == .permission ? .error : .info)
            )
            .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if row.state == .permission {
            HStack(spacing: 5) {
              Button("Negar") { Task { await store.reply(row, allow: false) } }
                .font(.system(size: 12))
                .foregroundStyle(theme.color(.text))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .contentShape(Capsule())
                .overlay { Capsule().strokeBorder(theme.color(.border), lineWidth: 1) }
                .buttonStyle(.plain)
              Button("Permitir") { Task { await store.reply(row, allow: true) } }
                .buttonStyle(.borderedProminent).tint(theme.color(.filledButton))
                .foregroundStyle(theme.color(.onFilledButton))
            }
            .disabled(store.busy.contains(row.id) || store.permission(row) == nil)
          } else {
            Button("Responder") { store.conversationPath.append(.init(id: row.id)) }
              .buttonStyle(.borderedProminent).tint(theme.color(.info))
              .foregroundStyle(theme.color(.onInfo))
          }
        }
        .font(.system(size: 12, weight: .medium))
        .buttonBorderShape(.capsule)
        .controlSize(.small)
      }
    }
    .padding(12)
    .background(theme.color(.surface).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.border), lineWidth: 0.75)
    }
  }

  @ViewBuilder private func rowActions(_ row: SessionRow) -> some View {
    Button("Abrir sessão", systemImage: "bubble.left") { store.conversationPath.append(.init(id: row.id)) }
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
  }
}

private struct Chip: View {
  @Environment(\.appTheme) private var theme
  let title: String
  let selected: Bool
  var running = false
  var count = 0

  var body: some View {
    HStack(spacing: 5) {
      if running { RunningArc(size: 9, filled: true) }
      Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
      if count > 0 {
        Text("\(count)").font(.system(size: 11, weight: .medium)).padding(.horizontal, 5).padding(
          .vertical, 1
        ).background(theme.color(.highlight), in: Capsule())
      }
    }
    .foregroundStyle(theme.color(selected ? .primary : .text))
    .padding(.horizontal, 12).frame(height: 32)
    .background(
      theme.color(selected ? .primary : .surface).opacity(selected ? 0.08 : 1), in: Capsule()
    )
    .overlay {
      Capsule().strokeBorder(theme.color(selected ? .primary : .border), lineWidth: 0.75)
    }
  }
}

private struct UsageMeter: View {
  @Environment(\.appTheme) private var theme
  let summary: Subscriptions.Summary?
  let name: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle().fill(theme.color(summary?.ready == true ? .success : .warning)).frame(
          width: 7, height: 7)
        Text(summary?.label(name) ?? "\(name) — · —").font(.system(size: 12.5)).foregroundStyle(
          theme.color(.text))
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
