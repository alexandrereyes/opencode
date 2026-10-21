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
  private var sections: [String] {
    items.reduce(into: []) { if !$0.contains($1.section) { $0.append($1.section) } }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if loading && items.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding(16).tint(theme.color(.primary))
        }
        if !loading && items.isEmpty {
          Text(failed ? "Não foi possível carregar sugestões" : "Nenhum item correspondente")
            .font(.subheadline).foregroundStyle(theme.color(.textSecondary)).padding(16)
        }
        ForEach(sections, id: \.self) { section in
          Text(section).font(.caption).foregroundStyle(theme.color(.textSecondary)).padding(
            .horizontal, 12
          ).padding(.top, 9).padding(.bottom, 4)
          ForEach(items.filter { $0.section == section }) { item in
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
                    Text(item.subtitle).font(.caption).foregroundStyle(theme.color(.textSecondary))
                      .lineLimit(2)
                  }
                }
                Spacer(minLength: 0)
              }.font(.system(size: 15)).foregroundStyle(theme.color(item.token.kind.role))
                .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                .background(
                  item.id == items.first?.id
                    ? theme.color(.text).opacity(0.07) : theme.color(.surface).opacity(0),
                  in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).accessibilityIdentifier("suggestion-\(item.token.id)")
          }
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
          let next = try await store.suggestions(trigger)
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
