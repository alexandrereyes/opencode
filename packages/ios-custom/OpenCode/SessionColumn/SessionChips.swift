import OpenCodeKit
import SwiftUI

/// Its own view so preview/streaming updates of the list never re-evaluate the chips.
struct SessionChips: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let store: SessionStore
  /// A confirmed preference change for a chip: removal or a move in the saved manual order.
  let action: (_ name: String, _ intent: PreferenceIntent) -> Void
  let add: () -> Void
  /// The displayed order changes only while the strip is idle and after the new order has held for `settle`,
  /// so chips never move under a finger and brief running/idle flips do not make the strip dance.
  @State private var shown: [String] = []
  @State private var scrolling = false
  @State private var pending: Task<Void, Never>?
  /// Running/unread chip keys of the shown order; a saved-order edit alone (Mover) applies without the delay.
  @State private var states: [Set<String>] = []
  private let settle = Duration.milliseconds(1500)

  private var manual: ChipManualOrder {
    ChipManualOrder(
      projects: store.selectedProjects.map { ($0.project.id, $0.directory) },
      chatsIndex: store.preferences?.data.projects["local"]?.chatsIndex, showsChats: store.chatRoot != nil)
  }
  var body: some View {
    let manual = manual
    let names = Dictionary(
      store.selectedProjects.map { ($0.project.id, $0.project.displayName) }, uniquingKeysWith: { first, _ in first })
    let chips = manual.keys.enumerated().map {
      ChipEntry(key: $0.element, name: names[$0.element] ?? "Chats", position: $0.offset)
    }
    let groups = SessionList.chipGroups(store.rows, chips: chips, chats: SessionStore.chatsSelection)
    let desired = groups.map(\.key)
    let current = [Set(groups.filter(\.running).map(\.key)), Set(groups.filter(\.unread).map(\.key))]
    let order = shown.filter(desired.contains) + desired.filter { !shown.contains($0) }
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ChipMenu {
            ForEach(SessionFilter.allCases.filter { $0 != .all }) { filter in
              Button(filter.rawValue) { store.filter = filter }
            }
          } label: {
            // "Todas" is an icon (a stack of every session); a state filter adds its name.
            Chip(
              title: store.filter == .all ? nil : store.filter.rawValue,
              selected: store.selectedProject == nil || store.filter != .all, symbol: "square.stack")
          } primaryAction: {
            store.filter = .all
            store.selectedProject = nil
          }
          .accessibilityLabel(store.filter.rawValue)
          .accessibilityAddTraits(store.selectedProject == nil || store.filter != .all ? .isSelected : [])
          .accessibilityHint("Mantenha pressionado para filtrar por estado")
          .accessibilityIdentifier("filter-all")
          ForEach(order, id: \.self) { key in
            if let group = groups.first(where: { $0.key == key }) { chip(group, manual).id(key) }
          }
          Button(action: add) {
            Chip(title: "+", selected: false)
          }
          .accessibilityLabel("Adicionar repositório aos filtros")
        }
      }
      #if os(macOS)
      // A Mac with "always show scroll bars" would otherwise draw a scroller under the chips.
      .scrollIndicators(.never)
      #else
      .scrollIndicators(.hidden)
      #endif
      .buttonStyle(.plain)
      .onScrollPhaseChange { _, phase in
        scrolling = phase != .idle
        if !scrolling { schedule(desired, current, proxy) }
      }
      .onAppear {
        shown = desired
        states = current
        // Reordering while a conversation covered the strip cannot scroll it; reveal the filter on return.
        reveal(proxy)
      }
      .onDisappear { pending?.cancel() }
      // `desired` changes only when some chip's running/unread state or the saved order changes.
      .onChange(of: desired) { _, value in schedule(value, current, proxy) }
    }
  }
  private func schedule(_ desired: [String], _ current: [Set<String>], _ proxy: ScrollViewProxy) {
    pending?.cancel()
    guard shown != desired else {
      states = current
      return
    }
    let delay = current == states ? Duration.zero : settle
    pending = Task { @MainActor in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, !scrolling, shown != desired else { return }
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { shown = desired }
      states = current
      reveal(proxy)
    }
  }
  /// Keeps the active filter on screen once the new positions are laid out (after the reorder animation).
  private func reveal(_ proxy: ScrollViewProxy) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      guard !scrolling, let selected = store.selectedProject, shown.contains(selected) else { return }
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { proxy.scrollTo(selected) }
    }
  }
  /// Antes/depois swap with the neighbour in the saved manual order (Chats included); running and unread chips may
  /// visually bypass that order.
  @ViewBuilder private func moves(_ key: String, _ name: String, _ manual: ChipManualOrder) -> some View {
    if let intent = manual.move(key, by: -1) {
      Button("Mover para antes", systemImage: "arrow.left") { action(name, intent) }
    }
    if let intent = manual.move(key, by: 1) {
      Button("Mover para depois", systemImage: "arrow.right") { action(name, intent) }
    }
  }
  @ViewBuilder private func chip(_ group: ChipGroup, _ manual: ChipManualOrder) -> some View {
    if group.key == SessionStore.chatsSelection {
      ChipMenu {
        moves(group.key, "Chats", manual)
      } label: {
        Chip(
          title: "Chats", selected: store.chatsSelected, running: group.running,
          count: group.requests, unread: group.unread, symbol: "bubble.left")
      } primaryAction: {
        store.selectedProject = store.chatsSelected ? nil : SessionStore.chatsSelection
      }
      .accessibilityLabel(group.unread ? "Chats, com não lidas" : "Chats")
      .accessibilityIdentifier("filter-chats")
    } else if let selected = store.selectedProjects.first(where: { $0.project.id == group.key }) {
      let name = selected.project.displayName
      ChipMenu {
        Button("Remover dos filtros", systemImage: "minus.circle", role: .destructive) {
          action(name, .close(directory: selected.directory))
        }
        moves(group.key, name, manual)
      } label: {
        Chip(
          title: name, selected: store.selectedProject == group.key, running: group.running,
          count: group.requests, unread: group.unread, icon: .of(selected.project))
      } primaryAction: {
        store.selectedProject = store.selectedProject == group.key ? nil : group.key
      }
      .accessibilityLabel(group.unread ? name + ", com não lidas" : name)
      .accessibilityIdentifier("filter-project-" + name)
    }
  }
}

/// A chip's menu: on the iPhone a long press opens it and a tap runs the primary action; on the Mac a click runs
/// the primary action and a right click opens the same items, as Mac controls do.
private struct ChipMenu<Items: View, Label: View>: View {
  @ViewBuilder let items: () -> Items
  @ViewBuilder let label: () -> Label
  let primaryAction: () -> Void

  var body: some View {
    #if os(macOS)
    Button(action: primaryAction, label: label).contextMenu(menuItems: items)
    #else
    Menu(content: items, label: label, primaryAction: primaryAction)
    #endif
  }
}

private struct Chip: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @ScaledMetric(relativeTo: .subheadline) private var minimumHeight = 36.0
  /// Nil draws an icon-only chip (its `symbol`), at least 44 pt wide.
  let title: String?
  let selected: Bool
  var running = false
  var count = 0
  /// The list rows' orange unread dot, as a corner badge that coexists with the running arc.
  var unread = false
  var symbol: String?
  /// The project's own icon (`project.icon`), beside the name.
  var icon: ProjectIcon?

  var body: some View {
    HStack(spacing: 8) {
      if running { RunningArc(size: 9, filled: true) }
      if let symbol { Image(systemName: symbol).appSymbol(.inline, weight: selected ? .semibold : .medium) }
      if let icon { ProjectIconImage(icon: icon) }
      if let title { Text(title).appFont(.secondary, weight: selected ? .semibold : .regular).lineLimit(1) }
      if count > 0 {
        Text("\(count)").appFont(.footnote, weight: .medium).monospacedDigit().padding(.horizontal, 5).padding(
          .vertical, 1
        ).background(theme.color(.highlight), in: Capsule())
      }
    }
    .foregroundStyle(theme.color(selected ? .textAccent : .text))
    .padding(.horizontal, title == nil ? 12 : 16).frame(minWidth: 44, minHeight: minimumHeight)
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
