import Foundation

/// The watch has no theme picker: it always uses `openchamber-dark` (contract). The roles it needs are copied here
/// so the watch app and its complication extension do not bundle the theme catalog; `WatchPaletteTests` checks
/// them against `OpenCode/Resources/Themes/openchamber-dark.json`.
public enum WatchPalette {
  public static let hex: [ThemeRole: String] = [
    .background: "#120f0e", .surface: "#161313", .surfaceRaised: "#171615", .border: "#2e2e2d",
    .textStrong: "#e4e0d6", .text: "#c9c5ba", .textSecondary: "#a29f94", .textWeak: "#6b6861",
    .primary: "#da7c47", .onPrimary: "#120f0e", .success: "#83b35f", .warning: "#c67f13", .error: "#dc6e5e",
    .accent: "#9988e5", .info: "#6da2ae",
  ]

  public static func color(_ role: ThemeRole) -> ThemeColor {
    ThemeColor(css: hex[role] ?? hex[.text]!)!
  }
}
