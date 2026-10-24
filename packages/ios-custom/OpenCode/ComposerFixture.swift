#if DEBUG
import OpenCodeKit
import SwiftUI

@MainActor enum ComposerFixtures {
  static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-OpenCodeComposerFixture") }
  static let sources: ComposerSources = {
    var sources = ComposerSources()
    sources.skills = try! JSONDecoder().decode([ComposerSkill].self, from: Data(#"[{"id":"sample","name":"sample","description":"Skill de teste"},{"id":"review","name":"review","description":"Revisar texto"}]"#.utf8))
    return sources
  }()
  static func suggestions(_ trigger: ComposerTrigger) -> [ComposerSuggestion] {
    let files = try! JSONDecoder().decode([ComposerFile].self, from: Data(#"[{"path":"README.md","type":"file"}]"#.utf8))
    return sources.suggestions(trigger, files: files, directory: "/fixture")
  }
}

struct ComposerFixtureRoot: View {
  @State private var appearance = AppearanceSettings()
  @Environment(\.colorScheme) private var scheme
  @State private var draft = ConversationDraft(server: "composer-fixture", id: "draft")
  @State private var store: ConversationStore
  @State private var owner = UUID()
  @State private var restored = false
  @State private var suggestionReturn = ComposerSuggestionReturn()
  init() {
    let client = OpenCodeClient.scrollFixture(configuration: .launch())
    _store = State(initialValue: ConversationStore(id: "fixture", client: client, hub: EventHub(client: client)))
  }
  var body: some View {
    let theme = appearance.theme(systemDark: scheme == .dark)
    NavigationStack {
      VStack(spacing: 12) {
        if let trigger = draft.trigger {
          ComposerSuggestions(store: store, trigger: trigger, ready: suggestionReturn) {
            draft.insert($0.token, replacing: trigger.range)
          }
        }
        ComposerTextView(draft: draft, theme: theme, expanded: true, owner: owner, firstSuggestion: {
          guard let trigger = draft.trigger, let first = suggestionReturn.first, first.trigger == trigger else { return nil }
          return { draft.insert(first.item.token, replacing: trigger.range) }
        })
          .frame(maxHeight: .infinity)
        Text("\(draft.document.validTokens.count) tokens").accessibilityIdentifier("fixture-tokens")
        Text(draft.document.text).lineLimit(1).accessibilityIdentifier("fixture-text")
        HStack {
          Button("Limpar") { draft.text = NSAttributedString(); draft.selection = NSRange(location: 0, length: 0); draft.focused = true }
          Button("Desfazer") { draft.input?.undoManager?.undo() }
          Button("Refazer") { draft.input?.undoManager?.redo() }
          Button("Salvar") { Task { await draft.persist() } }
        }
      }
      .padding(20).background(theme.color(.background)).navigationTitle("Compositor de teste")
      .task {
        guard !restored else { return }
        restored = true
        await draft.load()
        draft.editorOwner = owner
        draft.focused = true
      }
    }
    .environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR"))
    .preferredColorScheme(appearance.colorScheme).tint(theme.color(.primary))
  }
}
#endif
