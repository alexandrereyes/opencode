import ActivityKit
import OpenCodeKit
import SwiftUI

/// The "Agentes" Live Activity of one server (`custom.live-activity`). The type name is the APNs `attributes-type`
/// of push-to-start, so it must not change.
struct AgentsActivityAttributes: ActivityAttributes {
  typealias ContentState = AgentsState
  /// Chosen by the app at `register`; identifies the server inside the app.
  let serverKey: String
  /// `ThemeRole` name → `#RRGGBBAA`, produced by the app and echoed verbatim by the backend.
  let theme: [String: String]

  func color(_ role: ThemeRole) -> Color {
    guard let value = AgentsTheme.color(theme, role) else { return Self.fallback(role) }
    return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.opacity)
  }

  /// Only for a theme missing a role (never sent by this app): semantic system colors, not fixed values.
  private static func fallback(_ role: ThemeRole) -> Color {
    switch role {
    case .background, .surface: Color(uiColor: .systemBackground)
    case .border: Color(uiColor: .separator)
    case .textSecondary, .textWeak: .secondary
    case .success: .green
    case .warning: .orange
    case .error: .red
    case .accent: .purple
    case .info: .teal
    case .primary: .orange
    default: .primary
    }
  }
}
