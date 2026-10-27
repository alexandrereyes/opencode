import OpenCodeKit
import SwiftUI

/// Its own view so preview/streaming updates of the list never re-evaluate the chips.
struct SessionChips: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let store: SessionStore
  let action: (_ directory: String, _ name: String, _ index: Int?) -> Void
  let add: () -> Void
  /// The displayed order changes only while the strip is idle and after the new order has held for `settle`,
  /// so chips never move under a finger and brief running/idle flips do not make the strip dance.
  @State private var shown: [String] = []
  @State private var scrolling = false
  @State private var pending: Task<Void, Never>?
  /// Running/unread chip keys of the shown order; a saved-order edit alone (Mover) applies without the delay.
  @State private var states: [Set<String>] = []
  private let settle = Duration.milliseconds(1500)

  /// Chats has no saved manual position; repositories use their index in `projects["local"]`.
  private var chips: [ChipEntry] {
    (store.chatRoot == nil ? [] : [ChipEntry(key: SessionStore.chatsSelection, name: "Chats", position: nil)])
      + store.selectedProjects.enumerated().map {
        ChipEntry(key: $0.element.project.id, name: $0.element.project.displayName, position: $0.offset)
      }
  }
  var body: some View {
    let groups = SessionList.chipGroups(store.rows, chips: chips, chats: SessionStore.chatsSelection)
    let desired = groups.map(\.key)
    let current = [Set(groups.filter(\.running).map(\.key)), Set(groups.filter(\.unread).map(\.key))]
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
      // Antes/depois edit the saved manual order; running and unread chips may visually bypass it.
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
