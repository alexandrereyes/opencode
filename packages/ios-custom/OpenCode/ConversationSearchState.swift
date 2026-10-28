import Observation
import OpenCodeKit
import SwiftUI

@MainActor @Observable final class ConversationSearchState {
  var open = false
  var query = ""
  private(set) var matches: [ConversationMatch] = []
  private(set) var index: Int?
  private(set) var paging = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var aligned: String?
  /// Desktop windows route navigation to their own transcript; nil preserves the iPhone's navigation owner.
  @ObservationIgnored var navigate: ((String, Double) -> Void)?
  var current: ConversationMatch? {
    index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
  }
  func update(_ store: ConversationStore, reset: Bool = false) {
    let previous = reset ? nil : current?.id
    matches = ConversationSearch.matches(query, messages: store.messages)
    index = previous.flatMap { id in matches.firstIndex { $0.id == id } }
      ?? (matches.isEmpty ? nil : 0)
    if reset { reveal(store) }
  }
  func move(_ delta: Int, store: ConversationStore) {
    guard !matches.isEmpty else { return }
    index = ((index ?? 0) + delta + matches.count) % matches.count
    reveal(store)
  }
  func reveal(_ store: ConversationStore) {
    guard let current else { return }
    aligned = nil
    if let navigate { navigate(current.messageID, 0); return }
    store.revealMessage(current.messageID, persist: false)
  }
  func align(_ match: ConversationMatch, offset: Double, store: ConversationStore) {
    guard current?.id == match.id, aligned != match.id else { return }
    aligned = match.id
    if let navigate { navigate(match.messageID, max(0, offset - 24)); return }
    store.revealMessage(match.messageID, offset: max(0, offset - 24), persist: false)
  }
  func older(_ store: ConversationStore) {
    guard !paging, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    paging = true
    let known = Set(matches.map(\.id))
    task = Task { @MainActor in
      defer { paging = false; task = nil }
      var pages = 0
      while ConversationSearch.continuePaging(hasOlder: store.hasOlder, pages: pages, foundNew: false) {
        guard !Task.isCancelled else { return }
        if store.paging {
          do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
          continue
        }
        let count = store.messages.count
        await store.older()
        guard !Task.isCancelled else { return }
        pages += 1
        update(store)
        if let found = matches.lastIndex(where: { !known.contains($0.id) }) {
          index = found
          reveal(store)
          return
        }
        if store.messages.count == count { return }
      }
    }
  }
  func cancelPaging() { task?.cancel() }
  func close() {
    cancelPaging()
    open = false
    query = ""
    matches = []
    index = nil
  }
}

struct ConversationSearchHighlight {
  var matches: [ConversationMatch] = []
  var current: String?
  var align: ((ConversationMatch, Double) -> Void)?
}
/// The alignment handler is stable for a conversation; matches and the current match are the rendered data.
extension ConversationSearchHighlight: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool { lhs.matches == rhs.matches && lhs.current == rhs.current }
}
extension EnvironmentValues {
  @Entry var conversationSearch = ConversationSearchHighlight()
}

struct ConversationSearchBar: View {
  @Environment(\.appTheme) private var theme
  let search: ConversationSearchState
  let store: ConversationStore
  var body: some View {
    VStack(spacing: 4) {
      if store.hasOlder && (search.index == nil || search.index == 0 || search.paging) {
        if search.paging {
          HStack {
            ProgressView().controlSize(.small)
            Text("Buscando mensagens anteriores…")
            Button("Cancelar") { search.cancelPaging() }
          }.font(.caption)
        } else {
          Button("Buscar em mensagens mais antigas") { search.older(store) }
            .font(.footnote).disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      HStack {
        Text(ConversationSearch.counter(index: search.index, count: search.matches.count))
          .font(.subheadline).monospacedDigit().accessibilityIdentifier("search-counter")
        Spacer()
        Button { search.move(-1, store: store) } label: { Image(systemName: "chevron.up") }
          .accessibilityLabel("Resultado anterior").frame(width: 44, height: 40)
        Button { search.move(1, store: store) } label: { Image(systemName: "chevron.down") }
          .accessibilityLabel("Próximo resultado").frame(width: 44, height: 40)
      }.disabled(search.matches.isEmpty)
    }
    .foregroundStyle(theme.color(.primary)).padding(.horizontal, 16).padding(.vertical, 5)
    .background(theme.color(.background))
  }
}
