import OpenCodeKit
import SwiftUI

/// The current server where Sessões' title was (approved option B, 3 November): its avatar with the connection dot,
/// its name and a chevron and, on the iPhone, the connection in words below. Shared by the iPhone header and the Mac
/// session column's title bar; the button around it opens the server list. Only the current server's connection is
/// known: the others are not monitored.
struct SessionServerTitle: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let entry: ServerSwitcher.Entry
  let connection: ServerSwitcher.Connection
  /// The Mac's title bar: one line, the connection as the avatar's dot only.
  var compact = false
  /// Another server needs Alexandre (stage 2 of the switch, each server's own state); nothing sets it yet.
  var othersNeedYou = false

  @ViewBuilder private var name: some View {
    if compact {
      Text(entry.server.title).font(.system(size: 13, weight: .semibold))
    } else {
      Text(entry.server.title).appFont(.heading, weight: .bold)
    }
  }

  var body: some View {
    HStack(spacing: compact ? 7 : 8) {
      ServerAvatar(entry: entry, size: compact ? 20 : 30, dot: connection.role)
        .overlay(alignment: .topLeading) {
          if othersNeedYou {
            Circle().fill(theme.color(.accent)).frame(width: 7, height: 7)
              .overlay { Circle().strokeBorder(theme.color(.background), lineWidth: 1) }.offset(x: -2, y: -2)
          }
        }
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          // Beside three 48-pt buttons the name gets about 140 pt: headline size, shrinking a little before it is cut
          // in the middle.
          name
            .foregroundStyle(theme.color(.textStrong))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
            .minimumScaleFactor(compact ? 1 : 0.85)
          Image(systemName: "chevron.down").font(.system(size: compact ? 10 : 12, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
        }
        if !compact {
          Text(connection.label).appFont(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }
      }
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Servidor \(entry.server.title), \(connection.label.lowercased())"
      + (othersNeedYou ? ", outro servidor precisa de você" : ""))
    .accessibilityHint("Abre a lista de servidores")
  }
}

/// A server's initials on its color, from the project avatars' palette, with an optional connection dot.
struct ServerAvatar: View {
  @Environment(\.appTheme) private var theme
  let entry: ServerSwitcher.Entry
  let size: CGFloat
  var dot: ThemeRole? = nil

  var body: some View {
    let colors = theme.avatar(entry.color)
    Text(entry.initials).font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(colors.text).frame(width: size, height: size)
      .background(colors.background, in: Circle())
      .overlay(alignment: .bottomTrailing) {
        if let dot {
          Circle().fill(theme.color(dot)).frame(width: max(7, size * 0.3), height: max(7, size * 0.3))
            .overlay { Circle().strokeBorder(theme.color(.background), lineWidth: max(1.5, size * 0.06)) }
            .offset(x: 1, y: 1)
        }
      }
      .accessibilityHidden(true)
  }
}

