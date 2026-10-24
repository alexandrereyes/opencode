#if DEBUG
import OpenCodeKit
import SwiftUI

@MainActor enum ScrollFixtures {
  static weak var scrollState: ConversationScrollState?
  static let mode: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-OpenCodeScrollFixture") else { return nil }
    guard arguments.indices.contains(index + 1) else { return "" }
    return arguments[index + 1]
  }()
  static let snapshot: ScrollFixtureSnapshot = {
    let snapshot = try! JSONDecoder().decode(
      ScrollFixtureSnapshot.self,
      from: Data(contentsOf: Bundle.main.url(forResource: "scroll-fixture", withExtension: "json")!))
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeContextUsageFixture") {
      return ContextUsageFixture.snapshot(snapshot)
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMarkdownFixture") {
      return MarkdownFixtures.snapshot(snapshot)
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureEmpty") {
      return ScrollFixtureSnapshot(
        messages: [], entries: snapshot.entries, projects: snapshot.projects,
        preferences: snapshot.preferences, models: snapshot.models)
    }
    guard ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureFollow") else { return snapshot }
    // A small, fully measured starting transcript separates real row growth from
    // the unrelated coordinate renumbering of hundreds of unmeasured List items.
    let rows = snapshot.messages.filter {
      $0.type == "assistant" && (100...200).contains($0.responseText.count)
    }.suffix(3).map { message in
      var row = message
      row.content = message.content?.filter { $0.type == "text" }
      return row
    }
    var user = snapshot.messages[snapshot.messages.count - 3]
    user.text = "Acompanhe o checklist sintético."
    return ScrollFixtureSnapshot(
      messages: [user] + rows,
      entries: snapshot.entries, projects: snapshot.projects, preferences: snapshot.preferences, models: snapshot.models)
  }()
}

struct ScrollFixtureSnapshot: Decodable {
  let messages: [ConversationMessage]
  let entries: [NavigationEntry]
  let projects: [Project]
  let preferences: Preferences
  let models: [ModelInfo]
}

struct ScrollFixtureRoot: View {
  @Environment(\.colorScheme) private var systemScheme
  @State private var appearance = AppearanceSettings()
  @State private var store: SessionStore

  init() {
    let store = SessionStore(
      configuration: ServerConfiguration(url: URL(string: "http://127.0.0.1:1")!),
      acceptsLaunchSession: false)
    let arguments = ProcessInfo.processInfo.arguments
    let index = arguments.firstIndex(of: "-OpenCodeFixturePosition")
    let position = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    let messages = ScrollFixtures.snapshot.messages
    let target: ReadingPosition.Target =
      position == "top" ? .message(id: messages[0].id, offset: 0)
      : position == "middle" ? .message(id: messages[messages.count / 2].id, offset: 0)
      // A reading bookmark above the tail: history above it has never been measured.
      : position == "nearTail" ? .message(id: messages[messages.count - 3].id, offset: 0)
      : .followTail
    store.reading.set(ReadingPosition(target), sessionID: "ses_scroll_0000")
    _store = State(initialValue: store)
  }

  var body: some View {
    let theme = appearance.theme(systemDark: systemScheme == .dark)
    Group {
      if ScrollFixtures.mode == "conversation" {
        NavigationStack {
          ConversationView(id: "ses_scroll_0000", sessions: store)
        }
      } else if ScrollFixtures.mode == "sessions" {
        SessionsView(store: store)
      } else {
        ContentUnavailableView(
          "Fixture desconhecida", systemImage: "exclamationmark.triangle",
          description: Text("Use conversation ou sessions. Nenhum servidor foi conectado."))
      }
    }
    .environment(\.appTheme, theme)
    .environment(\.locale, Locale(identifier: "pt_BR"))
    .preferredColorScheme(appearance.colorScheme)
    .tint(theme.color(.primary))
    .background(ThemeChrome(theme: theme).frame(width: 0, height: 0))
    .background(ScrollFixtureDriver().frame(width: 0, height: 0))
    .background(ComposerTypingDriver().frame(width: 0, height: 0))
    .background(MarkdownFixtureCaptureDriver().frame(width: 0, height: 0))
    .task { await store.run() }
  }
}
#endif
