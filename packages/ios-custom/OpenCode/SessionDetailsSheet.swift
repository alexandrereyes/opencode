import OpenCodeKit
import SwiftUI

struct SessionDetailsSheet: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  let store: ConversationStore
  let project: Project?
  var isChat = false
  var showLocation = true
  let context: () -> Void
  @State private var services: SessionServices?
  @State private var detent = PresentationDetent.large
  @State private var mcpsExpanded = true
  @State private var skillsExpanded = false
  @State private var pluginsExpanded = false
  private static let collapsedLimit = 5
  var body: some View {
    NavigationStack {
      List {
        SessionUsageSection(store: store)
        Section("Sessão") {
          LabeledContent("Projeto", value: isChat ? "Sem repositório" : project?.displayName ?? "Indisponível")
          if showLocation {
            let directory = store.located?.worktree ?? store.session?.location.directory
            if let directory {
              NavigationLink(value: FileExplorerRoute(path: directory)) {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Diretório de trabalho").foregroundStyle(theme.color(.textSecondary))
                  Text(directory).font(.footnote)
                }
              }
              .contextMenu {
                Button("Copiar caminho", systemImage: "doc.on.doc") { UIPasteboard.general.string = directory }
              }
              .accessibilityHint("Abre os arquivos deste diretório")
              .accessibilityIdentifier("session-details-directory")
            } else {
              LabeledContent("Diretório de trabalho", value: "Indisponível")
            }
            LabeledContent("Branch", value: services?.branch ?? (services == nil ? "Carregando…" : "Indisponível"))
          }
          if let changes = services?.changes {
            HStack {
              Text("Alterações atuais")
              Spacer()
              Text("+\(changes.reduce(0) { $0 + $1.additions })").foregroundStyle(theme.color(.diffAdd))
              Text("−\(changes.reduce(0) { $0 + $1.deletions })").foregroundStyle(theme.color(.diffDelete))
            }
          } else {
            LabeledContent("Alterações atuais", value: services == nil ? "Carregando…" : "Indisponível")
          }
          Button("Uso de contexto", systemImage: "chart.pie") { dismiss(); context() }
        }
        mcpSection
        collapsibleSection("Skills", id: "skills", items: services?.skills, expanded: $skillsExpanded,
          empty: "Nenhuma skill carregada") { skill in
          VStack(alignment: .leading, spacing: 2) {
            Text(skill.name).lineLimit(2)
            if skill.id != skill.name {
              Text(skill.id).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
            }
          }.accessibilityElement(children: .combine).accessibilityIdentifier("session-details-skill-" + skill.id)
        }
        collapsibleSection("Plugins", id: "plugins", items: services?.plugins, expanded: $pluginsExpanded,
          empty: "Nenhum configurado") { item in
          LabeledContent {
            Text(item.label).foregroundStyle(theme.color(role(item.state)))
          } label: { Text(item.id).lineLimit(2) }
            .accessibilityElement(children: .combine).accessibilityIdentifier("session-details-plugin-" + item.id)
        }
      }
      .scrollContentBackground(.hidden).background(theme.color(.background))
      .foregroundStyle(theme.color(.textStrong))
      .navigationTitle("Detalhes da sessão").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Atualizar", systemImage: "arrow.clockwise") { Task { await refresh() } }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } }
      }
      .navigationDestination(for: FileExplorerRoute.self) { route in
        FileExplorerView(path: route.path, changes: FileExplorer.changes(services?.changes ?? [],
          root: store.located?.worktree ?? store.session?.location.directory ?? ""))
          .onAppear { detent = .large }
      }
    }
    // The conversation's viewer cannot present over this sheet, so files open from here.
    .modifier(FileViewerHost())
    .tint(theme.color(.primary)).presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
    .toastOverlay(store.toast)
    .task { await refresh() }
  }
  private func refresh() async {
    async let mcps: Void = store.mcps.refresh()
    services = await store.services()
    await mcps
  }
  /// The same live MCP state and toggle as the composer's MCP panel, listed in a stable order while toggling.
  private var mcpSection: some View {
    let mcps = store.mcps
    let servers = mcps.chips.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return Section {
      if mcpsExpanded {
        if servers.isEmpty {
          Text(mcps.loading ? "Carregando…" : mcps.failed ? "Indisponível" : "Nenhum configurado")
            .foregroundStyle(theme.color(.textSecondary))
        }
        ForEach(servers) { server in mcpRow(server) }
        if mcps.failed && !mcps.loading && !mcps.unsupported {
          Button("Não foi possível carregar · Tentar novamente") { Task { await mcps.refresh() } }
            .appFont(.caption)
        }
      }
    } header: {
      sectionHeader("MCP", id: "mcp", count: servers.count, expanded: $mcpsExpanded)
    }.listRowBackground(theme.color(.toolSurface))
  }
  private func mcpRow(_ server: MCPServer) -> some View {
    let state = server.status.status
    return Toggle(isOn: Binding(get: { server.enabled }, set: { _ in Task { await store.mcps.toggle(server) } })) {
      VStack(alignment: .leading, spacing: 3) {
        Text(server.name).lineLimit(2)
        HStack(spacing: 5) {
          Circle().fill(theme.color(mcpRole(state))).frame(width: 6, height: 6)
          Text(state.label)
        }.appFont(.caption).foregroundStyle(theme.color(.textSecondary))
        if let error = server.status.error, state == .failed || state == .needsAuth {
          Text(error).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(3)
        }
      }
    }
    .disabled(state == .pending || state == .unknown)
    .accessibilityValue(state.label)
    .accessibilityHint("Altera o MCP para todas as sessões deste diretório.")
    .accessibilityIdentifier("session-details-mcp-" + server.name)
  }
  private func mcpRole(_ state: MCPServer.State) -> ThemeRole {
    switch state {
    case .connected: .success
    case .failed: .error
    case .needsAuth: .warning
    default: .textWeak
    }
  }
  /// Collapsed sections show their first `collapsedLimit` rows and offer the rest on demand.
  private func collapsibleSection<Item: Identifiable, Row: View>(
    _ title: String, id: String, items: [Item]?, expanded: Binding<Bool>, empty: String,
    @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    Section {
      if let items {
        if items.isEmpty { Text(empty).foregroundStyle(theme.color(.textSecondary)) }
        ForEach(expanded.wrappedValue ? items : Array(items.prefix(Self.collapsedLimit))) { item in row(item) }
        if items.count > Self.collapsedLimit {
          Button(expanded.wrappedValue ? "Mostrar menos" : "Mostrar todos (\(items.count))") {
            withAnimation { expanded.wrappedValue.toggle() }
          }.foregroundStyle(theme.color(.primary)).accessibilityIdentifier("session-details-\(id)-more")
        }
      } else {
        Text(services == nil ? "Carregando…" : "Indisponível").foregroundStyle(theme.color(.textSecondary))
      }
    } header: {
      sectionHeader(title, id: id, count: items?.count ?? 0, expanded: expanded,
        collapsible: (items?.count ?? 0) > Self.collapsedLimit)
    }.listRowBackground(theme.color(.toolSurface))
  }
  @ViewBuilder private func sectionHeader(_ title: String, id: String, count: Int, expanded: Binding<Bool>,
    collapsible: Bool = true) -> some View {
    let label = HStack(spacing: 6) {
      Text(title)
      if count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(theme.color(.textWeak)) }
      Spacer()
      if collapsible {
        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
          .foregroundStyle(theme.color(.textSecondary))
      }
    }.contentShape(.rect)
    if collapsible {
      Button {
        withAnimation { expanded.wrappedValue.toggle() }
      } label: { label }
      .buttonStyle(.plain)
      .accessibilityLabel(title)
      .accessibilityValue(expanded.wrappedValue ? "Expandida" : "Recolhida")
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("session-details-\(id)-header")
    } else {
      label.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("session-details-\(id)-header")
    }
  }
  private func role(_ state: SessionService.State) -> ThemeRole {
    switch state {
    case .active: .success
    case .failed: .error
    case .needsAuth, .pending: .warning
    case .disabled, .unavailable: .textSecondary
    }
  }
}

/// Move actions for a Session whose directory vanished, like the web's location-missing dock.
struct ConversationRelocation {
  let root: String
  let worktrees: [WorktreeChoice]
  let children: Int
  /// The web disables moving while the Session runs.
  let running: Bool
  let moving: Bool
  let move: (_ directory: String, _ children: Bool) -> Void
}

struct ConversationNoticeView: View {
  @Environment(\.appTheme) private var theme
  let notice: ConversationNotice
  var showDirectory = true
  var relocation: ConversationRelocation?
  let retry: () -> Void
  @State private var withChildren = true
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(notice == .incompatible ? "Servidor incompatível" : "Diretório indisponível", systemImage: "exclamationmark.triangle")
        .font(.subheadline.weight(.semibold))
      if case .missingDirectory(let directory) = notice {
        Text("O diretório desta sessão não existe mais. O histórico continua disponível, mas não é possível enviar mensagens.")
        if showDirectory { Text(directory).font(.caption).textSelection(.enabled) }
      } else {
        Text("Este servidor não oferece a API do OpenCode V2. Atualize o servidor para continuar.")
      }
      if let relocation { actions(relocation) }
      Button("Tentar novamente", action: retry).fontWeight(.medium)
    }
    .font(.footnote).foregroundStyle(theme.color(.textStrong)).padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.warning).opacity(0.12))
    // Contain the children so the actions keep their own identifiers.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("conversation-notice")
  }
  @ViewBuilder private func actions(_ relocation: ConversationRelocation) -> some View {
    let disabled = relocation.running || relocation.moving
    let children = relocation.children > 0 && withChildren
    Button {
      relocation.move(relocation.root, children)
    } label: {
      Text(relocation.moving ? "Movendo sessão…" : "Mover para o repositório local").fontWeight(.semibold)
    }
    .buttonStyle(.borderedProminent).tint(theme.color(.filledButton)).foregroundStyle(theme.color(.onFilledButton))
    .disabled(disabled).accessibilityIdentifier("notice-move-root")
    if !relocation.worktrees.isEmpty {
      Menu {
        ForEach(relocation.worktrees) { choice in
          Button(choice.label) { relocation.move(choice.directory, children) }
        }
      } label: {
        Label("Escolher worktree", systemImage: "arrow.triangle.branch").fontWeight(.medium)
      }
      .disabled(disabled).accessibilityIdentifier("notice-choose-worktree")
    }
    if relocation.children > 0 {
      Toggle(isOn: $withChildren) {
        Text(relocation.children == 1 ? "Mover a subsessão junto" : "Mover as \(relocation.children) subsessões junto")
      }
      .tint(theme.color(.primary)).disabled(disabled).accessibilityIdentifier("notice-move-children")
    }
    if relocation.running {
      Text("Disponível quando a sessão terminar de executar.").font(.caption)
        .foregroundStyle(theme.color(.textSecondary))
    }
  }
}
