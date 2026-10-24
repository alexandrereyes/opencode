#if DEBUG
import OpenCodeKit
import SwiftUI

@MainActor enum MCPFixtures {
  static var mode: String? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "-OpenCodeMCPFixture"), args.indices.contains(index + 1),
      ["http://127.0.0.1:4177", "http://127.0.0.1:4183"].contains(ServerConfiguration.launch().url.absoluteString)
    else { return nil }
    return args[index + 1]
  }
}

struct MCPFixtureRoot: View {
  @Environment(\.colorScheme) private var scheme
  @State private var appearance = AppearanceSettings()
  @State private var sessions: SessionStore
  @State private var prepared = false
  init() {
    let configuration = ServerConfiguration.launch()
    _sessions = State(initialValue: SessionStore(configuration: configuration,
      acceptsLaunchSession: false, client: .mcpFixture(configuration: configuration, scenario: MCPFixtures.mode ?? "")))
  }
  var body: some View {
    let theme = appearance.theme(systemDark: scheme == .dark)
    NavigationStack {
      if !prepared { ProgressView() }
      else if MCPFixtures.mode == "new-session" { NewSessionView(sessions: sessions) }
      else { ConversationView(id: "ses_mcp_fixture", sessions: sessions) }
    }.environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR"))
      .preferredColorScheme(appearance.colorScheme).tint(theme.color(.primary))
      .background(ThemeChrome(theme: theme).frame(width: 0, height: 0))
      .task {
        guard !prepared else { return }
        let draft = sessions.drafts.draft("ses_mcp_fixture")
        await draft.load()
        await draft.clear()
        // Arrange before mounting; typeText can replace the simulator's software keyboard.
        if MCPFixtures.mode == "pending" {
          let text = "Meu rascunho com MCPs"
          draft.text = NSAttributedString(string: text)
          draft.selection = NSRange(location: text.utf16.count, length: 0)
        }
        prepared = true
      }
  }
}
#endif
