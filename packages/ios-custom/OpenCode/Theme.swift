import OpenCodeKit
import SwiftUI

struct AppTheme: Sendable {
  private let definition: ThemeDefinition
  var id: String { definition.id }
  var dark: Bool { definition.dark }

  static let selected: AppTheme = {
    let arguments = ProcessInfo.processInfo.arguments
    let argument = arguments.firstIndex(of: "-OpenCodeTheme").flatMap {
      arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
    }
    return load(
      argument ?? UserDefaults.standard.string(forKey: "OpenCodeTheme") ?? "openchamber-dark")
  }()

  static func load(_ id: String) -> AppTheme {
    let url =
      Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "Themes")
      ?? Bundle.main.url(forResource: id, withExtension: "json")
    guard let url, let data = try? Data(contentsOf: url),
      let definition = try? JSONDecoder().decode(ThemeDefinition.self, from: data)
    else {
      if id != "openchamber-dark" { return load("openchamber-dark") }
      preconditionFailure(
        "Os temas do app não foram incluídos no build. Execute script/generate-themes.ts.")
    }
    return Self(definition: definition)
  }

  func color(_ role: ThemeRole) -> Color { Color(definition.color(role)) }
  func uiColor(_ role: ThemeRole) -> UIColor { UIColor(color(role)) }
  func avatar(_ color: String) -> (background: Color, text: Color) {
    let avatar = definition.avatar(ThemeAvatar.allCases.first { $0.name == color } ?? .lime)
    return (Color(avatar.background), Color(avatar.text))
  }
  func agentColor(_ agent: AgentInfo?, id: String) -> Color {
    if let css = agent?.color, let color = ThemeColor(css: css) {
      return Color(definition.overriding(.agentExplicit, with: color).color(.agentExplicit))
    }
    return self.color(agentRole(agent, id: id))
  }
}

extension Color {
  fileprivate init(_ color: ThemeColor) {
    self.init(
      .sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.opacity)
  }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = AppTheme.selected }
extension EnvironmentValues {
  var appTheme: AppTheme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}
