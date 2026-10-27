#if DEBUG
import OpenCodeKit
import SwiftUI

/// `-OpenCodeConversationTitleFixture` renders the Mac's chat title bar from the shared avatar and title,
/// with synthetic values, so its capture covers the variant the iPhone never shows.
@MainActor enum ConversationTitleFixtures {
  static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-OpenCodeConversationTitleFixture") }
}

struct ConversationTitleFixtureRoot: View {
  @State private var appearance = AppearanceSettings()
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let theme = appearance.theme(systemDark: scheme == .dark)
    VStack(spacing: 0) {
      ConversationTitleBar(
        avatar: ConversationAvatar(context: 0.38, master: false,
          colors: theme.avatar(SessionList.avatarColor(nil, fallback: "project_scroll_0")),
          monogram: SessionList.monogram("opencode2")),
        title: ConversationTitle(title: "App Mac", subtitle: "opencode2-mac-app-mocks", status: "trabalhando…", waiting: false),
        newSession: {}
      ) {
        Menu {
          Button("Buscar na conversa", systemImage: "magnifyingglass") {}
          Button("Renomear", systemImage: "pencil") {}
        } label: {
          Image(systemName: "ellipsis").appSymbol(.navigation).foregroundStyle(theme.color(.text))
            .frame(width: 36, height: 36).glassEffect(.regular.interactive(), in: .circle)
        }
        .accessibilityLabel("Mais opções").accessibilityIdentifier("conversation-title-bar-menu")
      }
      .accessibilityElement(children: .contain).accessibilityIdentifier("conversation-title-bar")
      Rectangle().fill(theme.color(.border)).frame(height: 0.7)
      Spacer()
    }
    .background(theme.color(.background))
    .environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR"))
    .preferredColorScheme(appearance.colorScheme).tint(theme.color(.primary))
  }
}
#endif
