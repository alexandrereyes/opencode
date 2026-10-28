import OpenCodeKit
import SwiftUI

/// Mac presentation only: the iPhone's chips, projection and saved project order remain untouched.
struct MacProjectRail: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let store: SessionStore
  let action: (String, PreferenceIntent) -> Void
  let add: () -> Void
  @State private var shown: [String] = []
  @State private var scrolling = false
  @State private var dragging = false
  @State private var pending: Task<Void, Never>?

  private var manual: ChipManualOrder {
    ChipManualOrder(projects: store.selectedProjects.map { ($0.project.id, $0.directory) },
      chatsIndex: store.preferences?.data.projects["local"]?.chatsIndex, showsChats: store.chatRoot != nil)
  }
  private var items: [ProjectRail.Item] {
    let names = Dictionary(store.selectedProjects.map { ($0.project.id, $0.project.displayName) }, uniquingKeysWith: { a, _ in a })
    return ProjectRail.items(rows: store.rows, chips: manual.keys.enumerated().map {
      ChipEntry(key: $0.element, name: names[$0.element] ?? "Chats", position: $0.offset)
    }, active: store.active)
  }

  var body: some View {
    let items = items
    let desired = items.map(\.id)
    let order = shown.filter(desired.contains) + desired.filter { !shown.contains($0) }
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(spacing: 9) {
          Button { Self.select(nil, store: store) } label: {
            tile(name: store.filter == .all ? "Todas" : store.filter.rawValue, symbol: "square.grid.2x2",
              selected: store.selectedProject == nil || store.filter != .all, count: store.rows.count)
          }
          .contextMenu {
            ForEach(SessionFilter.allCases) { filter in Button(filter.rawValue) { store.filter = filter } }
          }
          .help("\(store.filter.rawValue) · \(store.rows.count) sessões")
          .accessibilityIdentifier("filter-all")
          ForEach(order, id: \.self) { key in
            if let item = items.first(where: { $0.id == key }) { project(item).id(key) }
          }
          Button(action: add) { tile(name: "Adicionar repositório", symbol: "plus", selected: false, count: 0) }
            .help("Adicionar repositório").accessibilityLabel("Adicionar repositório aos filtros")
        }.padding(.vertical, 12)
      }
      .scrollIndicators(.hidden)
      .onAppear { shown = desired }
      .onDisappear { pending?.cancel() }
      .onChange(of: desired) { _, next in schedule(next) }
      .onChange(of: manual.keys) { _, _ in shown = desired }
      .onChange(of: store.selectedProject) { _, key in if let key { proxy.scrollTo(key) } }
      .onScrollPhaseChange { _, phase in scrolling = phase != .idle; if !scrolling { schedule(desired) } }
    }
    .frame(width: 52).frame(maxHeight: .infinity)
    .background(theme.color(.surface).opacity(0.35))
    .overlay(alignment: .trailing) { Rectangle().fill(theme.color(.border)).frame(width: 0.7) }
    .buttonStyle(.plain).accessibilityIdentifier("project-rail")
  }

  /// The exact chip semantics, also used by window search.
  static func select(_ key: String?, store: SessionStore) {
    if key == nil { store.filter = .all; store.selectedProject = nil; return }
    store.selectedProject = store.selectedProject == key ? nil : key
  }

  private func schedule(_ desired: [String]) {
    pending?.cancel()
    guard shown != desired else { return }
    pending = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1500))
      guard !Task.isCancelled, !scrolling, !dragging else { return }
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { shown = desired }
    }
  }

  private func project(_ item: ProjectRail.Item) -> some View {
    let selected = store.selectedProjects.first { $0.project.id == item.id }
    let name = selected?.project.displayName ?? "Chats"
    return Button { Self.select(item.id, store: store) } label: {
      tile(name: name, symbol: selected == nil ? "bubble.left" : nil, project: selected?.project,
        selected: store.selectedProject == item.id, count: item.count, group: item.group)
    }
    .help("\(name) · \(item.count) sessões")
    .accessibilityLabel("\(name), \(item.count) sessões" + (item.group.running ? ", trabalhando" : "")
      + (item.group.requests > 0 ? ", precisa de você" : "") + (item.group.unread ? ", com não lidas" : ""))
    .accessibilityAddTraits(store.selectedProject == item.id ? .isSelected : [])
    .accessibilityIdentifier(selected == nil ? "filter-chats" : "filter-project-" + name)
    .contextMenu {
      if let selected {
        Button("Remover dos filtros", systemImage: "minus.circle", role: .destructive) {
          action(name, .close(directory: selected.directory))
        }
        let repositories = ChipManualOrder(projects: manual.projects, chatsIndex: nil, showsChats: false)
        if let before = repositories.move(item.id, by: -1) {
          Button("Mover para antes", systemImage: "arrow.up") { action(name, before) }
        }
        if let after = repositories.move(item.id, by: 1) {
          Button("Mover para depois", systemImage: "arrow.down") { action(name, after) }
        }
      }
    }
    .onDrag {
      dragging = true
      return NSItemProvider(object: item.id as NSString)
    }
    .dropDestination(for: String.self) { values, _ in
      dragging = false
      guard let key = values.first, let intent = ProjectRail.drop(key, onto: item.id, manual: manual) else { return false }
      Task { await store.mutate(intent) }
      return true
    } isTargeted: { targeted in if !targeted { dragging = false } }
  }

  private func tile(name: String, symbol: String?, project: Project? = nil, selected: Bool,
    count: Int, group: ChipGroup? = nil) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10).fill(theme.color(selected ? .primary : .surface).opacity(selected ? 0.10 : 1))
        .frame(width: 40, height: 42)
      Group {
        if let project, let icon = ProjectIcon.of(project) {
          MacRailProjectIcon(icon: icon)
        } else if let symbol {
          Image(systemName: symbol).font(.system(size: 20, weight: .medium))
        } else {
          Text(SessionList.monogram(name)).font(.system(size: 13, weight: .semibold))
        }
      }
      .foregroundStyle(theme.color(.text)).frame(width: 32, height: 32)
      .background(theme.color(.highlight).opacity(symbol == nil ? 0.45 : 0), in: RoundedRectangle(cornerRadius: 8))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .frame(width: 52, height: 44)
    .overlay(alignment: .leading) { if selected { Capsule().fill(theme.color(.primary)).frame(width: 3, height: 28) } }
    .overlay(alignment: .bottomTrailing) {
      if count > 0 {
        Text(count > 99 ? "99+" : "\(count)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
          .foregroundStyle(theme.color(.text)).padding(.horizontal, 4).frame(minHeight: 15)
          .background(theme.color(.surfaceRaised), in: Capsule()).padding(.trailing, 3)
      }
    }
    .overlay(alignment: .bottomLeading) { if group?.running == true { dot(.success).offset(x: 7, y: 0) } }
    .overlay(alignment: .topLeading) { if (group?.requests ?? 0) > 0 { dot(.accent).offset(x: 7, y: 0) } }
    .overlay(alignment: .topTrailing) { if group?.unread == true { dot(.primary).offset(x: -6, y: 0) } }
    .contentShape(Rectangle())
  }

  private func dot(_ role: ThemeRole) -> some View {
    Circle().fill(theme.color(role)).frame(width: 7, height: 7)
      .overlay { Circle().strokeBorder(theme.color(.background), lineWidth: 1) }.accessibilityHidden(true)
  }
}

private struct MacRailProjectIcon: View {
  let icon: ProjectIcon
  @State private var image: CGImage?
  var body: some View {
    Group {
      if let image = ProjectIconCache.shared.cached(icon) ?? image {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      }
    }
    .task(id: icon.key) { image = await ProjectIconCache.shared.image(icon) { await ProjectIconRenderer.render($0, pixels: $1) } }
  }
}
