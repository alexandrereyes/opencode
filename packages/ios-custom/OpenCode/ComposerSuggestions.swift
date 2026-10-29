import OpenCodeKit
import SwiftUI

/// The panel's first item once loaded for its trigger, for Return in the editor. Not observed:
/// filling it must not re-render the composer.
final class ComposerSuggestionReturn {
  var first: (trigger: ComposerTrigger, item: ComposerSuggestion)?
}

/// A movable selection in the panel (the Mac's ↑/↓, ⌃N/⌃P, Return and Tab): the selectable items loaded for the
/// current trigger and the highlighted one. The iPhone passes none and keeps the first item.
@MainActor @Observable final class ComposerSuggestionHighlight {
  private(set) var trigger: ComposerTrigger?
  private(set) var items: [ComposerSuggestion] = []
  private(set) var index = 0
  var selected: ComposerSuggestion? { items.indices.contains(index) ? items[index] : nil }

  func load(_ trigger: ComposerTrigger, items: [ComposerSuggestion]) {
    // A refresh of the same trigger (an app listing arriving) keeps the highlighted item when it is still there.
    let kept = self.trigger == trigger ? selected?.id : nil
    self.trigger = trigger
    self.items = items
    index = kept.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
  }

  func clear() {
    trigger = nil
    items = []
    index = 0
  }

  /// Moves the highlight, wrapping around the list. False when there is nothing to move through.
  @discardableResult func move(_ delta: Int) -> Bool {
    guard !items.isEmpty else { return false }
    index = (index + delta + items.count) % items.count
    return true
  }

  func selected(for trigger: ComposerTrigger) -> ComposerSuggestion? { self.trigger == trigger ? selected : nil }
}

struct ComposerSuggestions: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let trigger: ComposerTrigger
  var ready: ComposerSuggestionReturn? = nil
  var highlight: ComposerSuggestionHighlight? = nil
  let select: (ComposerSuggestion) -> Void
  @State private var items: [ComposerSuggestion] = []
  @State private var loading = true
  @State private var failed = false
  @State private var shown: ComposerTrigger?
  private struct Load: Equatable {
    let trigger: ComposerTrigger
    let apps: Int
  }
  /// The highlighted row: the movable selection where there is one, else the first item (Return's pick).
  private var highlighted: String? { highlight?.selected(for: trigger)?.id ?? items.first?.id }
  var body: some View {
    ScrollViewReader { proxy in
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if loading && items.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding(16).tint(theme.color(.primary))
        }
        if !loading && items.isEmpty {
          Text(failed ? "Não foi possível carregar sugestões" : "Nenhum item correspondente")
            .appFont(.preview).foregroundStyle(theme.color(.textSecondary)).padding(16)
        }
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          if index == 0 || item.section != items[index - 1].section {
            Text(item.section).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).padding(
              .horizontal, 12
            ).padding(.top, 9).padding(.bottom, 4)
          }
          Button {
            select(item)
          } label: {
            HStack(spacing: 10) {
              if item.token.kind == .agent {
                AgentPixels(
                  color: theme.agentColor(
                    store.agents.first { $0.id == item.token.id }, id: item.token.id),
                  running: false)
              } else {
                Image(systemName: item.icon).frame(width: 20)
              }
              VStack(alignment: .leading, spacing: 3) {
                title(item)
                if !item.subtitle.isEmpty {
                  Text(item.subtitle).appFont(.caption).foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(2)
                }
              }
              Spacer(minLength: 0)
            }.appFont(.preview).foregroundStyle(theme.color(item.token.kind.role))
              .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
              .background(
                item.id == highlighted
                  ? theme.color(.text).opacity(0.07) : theme.color(.surface).opacity(0),
                in: RoundedRectangle(cornerRadius: 9))
          }.buttonStyle(.plain).accessibilityIdentifier("suggestion-\(item.token.id)")
            .disabled(!selectable(item)).opacity(selectable(item) ? 1 : 0.4)
            .id(item.id)
        }
      }.padding(6)
    }
    // The highlighted row scrolls into view as the arrows move it.
    .onChange(of: highlight?.index) { _, _ in
      guard let id = highlight?.selected(for: trigger)?.id else { return }
      proxy.scrollTo(id)
    }
    }.frame(maxHeight: 250).fixedSize(horizontal: false, vertical: true)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      .overlay {
        RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.border), lineWidth: 0.7)
      }
      .task(
        id: Load(trigger: trigger, apps: trigger.character == "@" ? ComposerAppMentions.shared.revision : 0)
      ) {
        // An app listing that arrives while the panel is open merges without re-debouncing or
        // dropping the item Return would choose.
        let arrival = shown == trigger
        shown = trigger
        if !arrival {
          ready?.first = nil
          highlight?.clear()
          loading = true
          failed = false
        }
        do {
          if !arrival { try await Task.sleep(for: .milliseconds(180)) }
          #if DEBUG && os(iOS)
          let next = ComposerFixtures.enabled || SideQuestionFixture.enabled ? ComposerFixtures.suggestions(trigger)
            : ComposerTypingDriver.scenario != nil ? ComposerTypingDriver.suggestions(trigger)
            : try await store.suggestions(trigger)
          #else
          let next = try await store.suggestions(trigger)
          #endif
          try Task.checkCancellation()
          items = next
          loading = false
          ready?.first = next.first.flatMap { selectable($0) ? (trigger, $0) : nil }
          highlight?.load(trigger, items: next.filter(selectable))
        } catch {
          if !Task.isCancelled {
            loading = false
            // A failed refresh after an app listing keeps what the panel already shows.
            if !arrival {
              failed = true
              items = []
            }
          }
        }
      }
      .onDisappear {
        ready?.first = nil
        highlight?.clear()
      }
  }
  private func selectable(_ item: ComposerSuggestion) -> Bool {
    !(store.isNewSession && item.token.value == "client" && ["compact", "btw"].contains(item.token.id))
  }
  @ViewBuilder private func title(_ item: ComposerSuggestion) -> some View {
    if item.token.kind == .file, let slash = item.title.lastIndex(of: "/") {
      Text(
        "\(Text(String(item.title[...slash])).foregroundColor(theme.color(.textSecondary)))\(Text(String(item.title[item.title.index(after: slash)...])))"
      )
      .lineLimit(1).truncationMode(.middle)
    } else {
      Text(item.title).lineLimit(1)
    }
  }
}
