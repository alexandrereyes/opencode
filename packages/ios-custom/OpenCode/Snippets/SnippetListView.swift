import OpenCodeKit
import SwiftUI

/// Você ▸ Snippets: search, scope filters, the catalog grouped by scope, swipe to duplicate or delete, tap to edit.
struct SnippetListView: View {
  @Environment(\.appTheme) private var theme
  let catalog: SnippetCatalog
  let projects: [Project]
  @State private var query = ""
  @State private var filter: Filter
  @State private var editor: SnippetEditorRoute?
  @State private var deleting: Snippet?
  @State private var failure: String?

  /// Todos, Globais or one project's chip.
  enum Filter: Hashable {
    case all, global
    case project(String)
  }

  /// `project` opens on that project's chip (Gerenciar snippets from a conversation), where a new one also starts.
  init(catalog: SnippetCatalog, projects: [Project], project: String? = nil) {
    self.catalog = catalog
    self.projects = projects
    _filter = State(initialValue: project.map(Filter.project) ?? .all)
  }

  private var sections: [SnippetSection] {
    SnippetLibrary.sections(catalog.items, projects: projects, filter: filter == .global ? .global : .all, query: query)
      .filter { section in
        guard case .project(let id) = filter else { return true }
        if case .project(let project) = section.scope { return project.id == id }
        return false
      }
  }
  /// One chip per project that has snippets, in the sections' order, plus the selected one (it may have none yet).
  private var chipProjects: [Project] {
    let used = SnippetLibrary.sections(catalog.items, projects: projects).compactMap { section in
      if case .project(let project) = section.scope { project } else { nil }
    }
    guard case .project(let id) = filter, !used.contains(where: { $0.id == id }),
      let selected = projects.first(where: { $0.id == id })
    else { return used }
    return [selected] + used
  }

  var body: some View {
    let sections = sections
    let shown = sections.reduce(0) { $0 + $1.items.count }
    List {
      if !catalog.items.isEmpty {
        chips
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
      }
      ForEach(sections) { section in
        Section {
          ForEach(section.items) { snippet in
            SnippetRow(snippet: snippet, overrides: SnippetRules.overridden(snippet, in: catalog.items) != nil) {
              editor = .init(snippet: snippet, editing: true)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button("Apagar", systemImage: "trash") { deleting = snippet }.tint(theme.color(.error))
              Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(snippet) }
                .tint(theme.color(.textWeak))
            }
            .contextMenu {
              Button("Editar", systemImage: "pencil") { editor = .init(snippet: snippet, editing: true) }
              Button("Duplicar", systemImage: "plus.square.on.square") { duplicate(snippet) }
              Button("Apagar", systemImage: "trash", role: .destructive) { deleting = snippet }
            }
          }
        } header: {
          SnippetSectionHeader(section: section)
        }
        .listRowBackground(theme.color(.surface))
      }
      if !catalog.items.isEmpty && (!query.isEmpty || filter != .all) {
        Text(shown == 0 ? "Nenhum snippet encontrado" : "\(shown) de \(catalog.items.count) snippets")
          .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          .listRowBackground(Color.clear).listRowSeparator(.hidden)
          .accessibilityIdentifier("snippets-count")
      }
    }
    .settingsList(theme)
    .overlay {
      if catalog.items.isEmpty {
        if catalog.loaded {
          SnippetEmptyState { editor = .init(snippet: newSnippet(), editing: false) }
        } else if catalog.failed {
          VStack(spacing: 12) {
            Text("Não foi possível carregar os snippets").foregroundStyle(theme.color(.textSecondary))
            Button("Tentar de novo") { Task { await catalog.load() } }.accessibilityIdentifier("snippets-retry")
          }
        } else {
          ProgressView().tint(theme.color(.primary))
        }
      }
    }
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar")
    .navigationTitle("Snippets")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Novo snippet", systemImage: "plus") { editor = .init(snippet: newSnippet(), editing: false) }
          .accessibilityIdentifier("snippets-new")
      }
    }
    .fullScreenCover(item: $editor) { route in
      SnippetEditorView(catalog: catalog, projects: projects, route: route).sessionAlertOverlay()
    }
    .confirmationDialog("Apagar #\(deleting?.name ?? "")?", isPresented: Binding(
      get: { deleting != nil }, set: { if !$0 { deleting = nil } }
    ), titleVisibility: .visible, presenting: deleting) { snippet in
      Button("Apagar snippet", role: .destructive) { Task { await remove(snippet) } }
      Button("Cancelar", role: .cancel) { deleting = nil }
    } message: { _ in Text("Ele deixa de aparecer no # do iPhone e do Mac. Mensagens já enviadas não mudam.") }
    .alert("Não foi possível apagar", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
      Button("OK") { failure = nil }
    } message: { Text(failure ?? "") }
    .refreshable { await catalog.load() }
    .task { await catalog.load() }

  }

  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        SnippetFilterChip(title: "Todos", selected: filter == .all) { filter = .all }
          .accessibilityIdentifier("snippets-filter-all")
        SnippetFilterChip(title: "Globais", selected: filter == .global) { filter = filter == .global ? .all : .global }
          .accessibilityIdentifier("snippets-filter-global")
        ForEach(chipProjects) { project in
          SnippetFilterChip(title: project.displayName, selected: filter == .project(project.id), project: project) {
            filter = filter == .project(project.id) ? .all : .project(project.id)
          }.accessibilityIdentifier("snippets-filter-" + project.displayName)
        }
      }.padding(.horizontal, 20).padding(.vertical, 4)
    }.scrollIndicators(.hidden)
  }

  /// A new snippet starts in the selected project, else global.
  private func newSnippet() -> Snippet {
    if case .project(let id) = filter { return Snippet(project: id) }
    return Snippet()
  }

  /// The copy opens in the editor: saving it is the confirmation.
  private func duplicate(_ snippet: Snippet) {
    editor = .init(snippet: SnippetLibrary.duplicate(snippet, in: catalog.items), editing: false)
  }

  private func remove(_ snippet: Snippet) async {
    deleting = nil
    do {
      try await catalog.remove(snippet.id)
      Haptics.play(.light)
    } catch { failure = error.localizedDescription }
  }
}

private struct SnippetRow: View {
  @Environment(\.appTheme) private var theme
  let snippet: Snippet
  let overrides: Bool
  let open: () -> Void
  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("#" + snippet.name).appFont(.body, weight: .semibold)
              .foregroundStyle(theme.color(.composerSnippet)).lineLimit(1)
            Spacer(minLength: 4)
            if overrides {
              Text("substitui o global").appFont(.micro).foregroundStyle(theme.color(.textSecondary))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(theme.color(.highlight), in: Capsule())
            }
          }
          if !snippet.description.isEmpty {
            Text(snippet.description).appFont(.secondary).foregroundStyle(theme.color(.textSecondary)).lineLimit(2)
          }
          if !snippet.aliases.isEmpty {
            Text(snippet.aliases.joined(separator: ", ")).appFont(.caption)
              .foregroundStyle(theme.color(.textWeak)).lineLimit(1)
          }
        }
        Image(systemName: "chevron.right").appSymbol(.inline).foregroundStyle(theme.color(.textWeak))
          .accessibilityHidden(true)
      }.padding(.vertical, 3).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Toque para editar")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("snippet-row-" + snippet.name)
  }
  private var accessibilityLabel: String {
    var parts = ["#" + snippet.name]
    if !snippet.description.isEmpty { parts.append(snippet.description) }
    if !snippet.aliases.isEmpty { parts.append("atalhos " + snippet.aliases.joined(separator: ", ")) }
    if overrides { parts.append("substitui o global") }
    return parts.joined(separator: ", ")
  }
}

private struct SnippetSectionHeader: View {
  @Environment(\.appTheme) private var theme
  let section: SnippetSection
  var body: some View {
    HStack(spacing: 10) {
      if case .project(let project) = section.scope {
        ProjectAvatar(project: project, size: 28, style: .caption)
      }
      Text(section.title).appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
    }
    .textCase(nil)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .accessibilityIdentifier("snippets-section-" + section.title)
  }
}

private struct SnippetFilterChip: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @ScaledMetric(relativeTo: .subheadline) private var minimumHeight = 36.0
  let title: String
  let selected: Bool
  var project: Project?
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        if let project { ProjectAvatar(project: project, size: 22, style: .micro) }
        Text(title).appFont(.secondary, weight: selected ? .semibold : .regular).lineLimit(1)
      }
      .foregroundStyle(theme.color(selected ? .textAccent : .text))
      .padding(.leading, project == nil ? 16 : 7).padding(.trailing, 16).frame(minWidth: 44, minHeight: minimumHeight)
      .background(theme.color(selected ? .primary : .surface).opacity(selected ? 0.08 : 1), in: Capsule())
      .overlay {
        Capsule().strokeBorder(theme.color(selected ? .primary : .controlBorder),
          lineWidth: selected ? 1.5 : 1 / displayScale)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// No snippet on the server yet.
struct SnippetEmptyState: View {
  @Environment(\.appTheme) private var theme
  let create: () -> Void
  var body: some View {
    VStack(spacing: 14) {
      Text("#").font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(theme.color(.composerSnippet))
        .frame(width: 84, height: 84)
        .background(theme.color(.composerSnippet).opacity(0.14), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityHidden(true)
      Text("Nenhum snippet ainda").appFont(.title, weight: .bold).foregroundStyle(theme.color(.textStrong))
        .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
      Text("Textos que você reutiliza. Digite \(Text("#").foregroundColor(theme.color(.composerSnippet))) no composer para inserir; no envio, o token vira o texto.")
        .appFont(.secondary).foregroundStyle(theme.color(.text)).multilineTextAlignment(.center)
      Button(action: create) {
        Text("Novo snippet").appFont(.body, weight: .semibold).frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(theme.color(.primary))
      .padding(.top, 6)
      .accessibilityIdentifier("snippets-empty-new")
      Text("Também dá para segurar uma mensagem e escolher Salvar como snippet.")
        .appFont(.caption).foregroundStyle(theme.color(.textSecondary)).multilineTextAlignment(.center)
    }
    .padding(.horizontal, 32)
    .frame(maxWidth: 440)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("snippets-empty")
  }
}
