import OpenCodeKit
import SwiftUI

/// The conversation's repository avatar inside the ring of its context window (neutral arc, the warning color
/// above 80%); the master shows its own symbol. The iPhone header and the Mac title bar share it.
struct ConversationAvatar: View {
  @Environment(\.appTheme) private var theme
  let context: Double?
  let master: Bool
  let colors: (background: Color, text: Color)
  let monogram: String

  var body: some View {
    ZStack {
      Circle().stroke(theme.color(.contextTrack), lineWidth: 2.5)
      if let fraction = context {
        Circle().trim(from: 0, to: min(1, max(0, fraction)))
          .stroke(
            theme.color(fraction > 0.8 ? .contextWarning : .contextFill),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
      Circle().fill(master ? theme.color(.surface) : colors.background).padding(4)
      if master {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .appSymbol(.action).foregroundStyle(theme.color(.accent))
      } else {
        Text(monogram).appFont(.message, weight: .medium).foregroundStyle(colors.text)
          .lineLimit(1).minimumScaleFactor(0.5)
      }
    }.frame(width: 44, height: 44)
  }
}

/// The title and its status line, like WhatsApp's "digitando…": `<branch> · trabalhando…`, with the status in
/// `success`, or `error` while the conversation waits for the user.
struct ConversationTitle: View {
  @Environment(\.appTheme) private var theme
  let title: String
  /// The iPhone's session switcher marks the title with a chevron.
  var switches = false
  let subtitle: String
  let status: String
  let waiting: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text(title)
          .appFont(.navigation).lineLimit(1)
          .accessibilityIdentifier("conversation-header-title")
        if switches {
          Image(systemName: "chevron.down").appSymbol(.disclosure).foregroundStyle(theme.color(.textSecondary))
            .accessibilityHidden(true)
        }
      }
      if !subtitle.isEmpty || !status.isEmpty {
        Text(
          "\(Text(subtitle))\(Text(status.isEmpty ? "" : (subtitle.isEmpty ? "" : " · ") + status).foregroundColor(theme.color(waiting ? .error : .success)))"
        )
        .appFont(.caption).lineLimit(1).foregroundStyle(theme.color(.textSecondary))
        .accessibilityIdentifier("conversation-header-subtitle")
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The Mac's chat header in the window's title bar: avatar, title and status line, then `…` and a primary `+`
/// for a new session. The iPhone keeps its own header (back, agents capsule and the UIKit `…` menu).
struct ConversationTitleBar<Menu: View>: View {
  @Environment(\.appTheme) private var theme
  let avatar: ConversationAvatar
  let title: ConversationTitle
  let newSession: () -> Void
  @ViewBuilder let menu: () -> Menu

  var body: some View {
    HStack(spacing: 10) {
      avatar
      title
      menu()
      Button(action: newSession) {
        Image(systemName: "plus").appSymbol(.action, weight: .semibold).foregroundStyle(theme.color(.onPrimary))
          .frame(width: 36, height: 36).background(theme.color(.primary), in: Circle())
      }
      .buttonStyle(.plain).accessibilityLabel("Nova sessão").accessibilityIdentifier("conversation-title-bar-new")
    }
    .padding(.horizontal, 14).padding(.vertical, 8)
  }
}
