import OpenCodeKit
import SwiftUI

struct ComposerSuggestions: View {
  @Environment(\.appTheme) private var theme
  let store: ConversationStore
  let trigger: ComposerTrigger
  let select: (ComposerSuggestion) -> Void
  @State private var items: [ComposerSuggestion] = []
  @State private var loading = true
  @State private var failed = false
  var body: some View {
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
                item.id == items.first?.id
                  ? theme.color(.text).opacity(0.07) : theme.color(.surface).opacity(0),
                in: RoundedRectangle(cornerRadius: 9))
          }.buttonStyle(.plain).accessibilityIdentifier("suggestion-\(item.token.id)")
            .disabled(store.isNewSession && item.token.value == "client" && ["compact", "btw"].contains(item.token.id))
            .opacity(store.isNewSession && item.token.value == "client" && ["compact", "btw"].contains(item.token.id) ? 0.4 : 1)
        }
      }.padding(6)
    }.frame(maxHeight: 250).fixedSize(horizontal: false, vertical: true)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
      .overlay {
        RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(.border), lineWidth: 0.7)
      }
      .task(id: trigger) {
        loading = true
        failed = false
        do {
          try await Task.sleep(for: .milliseconds(180))
          #if DEBUG
          let next = ComposerFixtures.enabled ? ComposerFixtures.suggestions(trigger) : try await store.suggestions(trigger)
          #else
          let next = try await store.suggestions(trigger)
          #endif
          try Task.checkCancellation()
          items = next
          loading = false
        } catch {
          if !Task.isCancelled {
            failed = true
            loading = false
            items = []
          }
        }
      }
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
