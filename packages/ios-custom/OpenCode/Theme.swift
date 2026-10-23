import OpenCodeKit
import Observation
import SwiftUI

struct AppTheme: Sendable {
  private let definition: ThemeDefinition
  var id: String { definition.id }
  var dark: Bool { definition.dark }

  static let selected = load("openchamber-dark")

  static let families: [ThemeFamily] = {
    let url = Bundle.main.url(forResource: "registry", withExtension: "json", subdirectory: "Themes")
      ?? Bundle.main.url(forResource: "registry", withExtension: "json")
    guard let url, let data = try? Data(contentsOf: url), let families = try? ThemeFamily.registry(data) else {
      preconditionFailure("O registro de temas não foi incluído no build.")
    }
    return families
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
  func value(_ role: ThemeRole) -> ThemeColor { definition.color(role) }
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

@MainActor @Observable final class AppearanceSettings {
  var family: String { didSet { UserDefaults.standard.set(family, forKey: "OpenCodeThemeFamily") } }
  var appearance: ThemeAppearance { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "OpenCodeAppearance") } }
  let override: String?
  init() {
    let defaults = UserDefaults.standard
    let legacy = defaults.string(forKey: "OpenCodeTheme")
    let family = defaults.string(forKey: "OpenCodeThemeFamily")
      ?? legacy.map { String($0.replacingOccurrences(of: "-dark", with: "").replacingOccurrences(of: "-light", with: "")) }
    let selection = ThemeSelection(family: family, appearance: defaults.string(forKey: "OpenCodeAppearance"),
                                   arguments: ProcessInfo.processInfo.arguments)
    self.family = AppTheme.families.contains { $0.id == selection.family } ? selection.family : "openchamber"
    appearance = selection.appearance
    override = selection.override
  }
  func theme(systemDark: Bool) -> AppTheme {
    AppTheme.load(ThemeSelection(family: family, appearance: appearance.rawValue,
                                arguments: override.map { ["-OpenCodeTheme", $0] } ?? []).resolve(systemDark: systemDark))
  }
  var colorScheme: ColorScheme? {
    if let override { return AppTheme.load(override).dark ? .dark : .light }
    switch appearance {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

/// Appearance proxies only affect new bars. Update already-mounted UIKit bars as well.
struct ThemeChrome: UIViewRepresentable {
  let theme: AppTheme
  func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }
  func updateUIView(_ view: UIView, context: Context) {
    let traits = UITraitCollection(preferredContentSizeCategory: context.environment.dynamicTypeSize.uiCategory)
    let navigation = UINavigationBarAppearance()
    navigation.configureWithDefaultBackground()
    navigation.titleTextAttributes = [
      .foregroundColor: theme.uiColor(.textStrong),
      .font: AppTypography.font(.heading, weight: .semibold, compatibleWith: traits),
    ]
    navigation.largeTitleTextAttributes = [
      .foregroundColor: theme.uiColor(.textStrong),
      .font: AppTypography.font(.largeTitle, weight: .bold, compatibleWith: traits),
    ]
    UINavigationBar.appearance().standardAppearance = navigation
    UINavigationBar.appearance().scrollEdgeAppearance = navigation
    UITabBar.appearance().unselectedItemTintColor = theme.uiColor(.glassSecondary)
    UITabBarItem.appearance().badgeColor = theme.uiColor(.error)
    // Native tabs cannot reflow; bound their scaled captions to the chrome's available height.
    let tabFont = AppTypography.font(.micro, weight: .medium, compatibleWith: traits)
    let tabAttributes: [NSAttributedString.Key: Any] = [
      .font: tabFont.withSize(min(tabFont.pointSize, AppTextStyle.caption.size)),
    ]
    UITabBarItem.appearance().setTitleTextAttributes(tabAttributes, for: .normal)
    UITabBarItem.appearance().setTitleTextAttributes(tabAttributes, for: .selected)
    func update(_ node: UIView) {
      if let bar = node as? UINavigationBar {
        bar.standardAppearance = navigation
        bar.scrollEdgeAppearance = navigation
        bar.tintColor = theme.uiColor(.primary)
      }
      if let bar = node as? UITabBar {
        bar.unselectedItemTintColor = theme.uiColor(.glassSecondary)
        bar.tintColor = theme.uiColor(.textAccent)
        bar.items?.forEach {
          let symbol = UIImage.SymbolConfiguration(pointSize: AppSymbolSize.tab.rawValue, weight: .medium)
          $0.image = $0.image?.applyingSymbolConfiguration(symbol) ?? $0.image
          $0.selectedImage = $0.selectedImage?.applyingSymbolConfiguration(symbol) ?? $0.selectedImage
          $0.setTitleTextAttributes(tabAttributes, for: .normal)
          $0.setTitleTextAttributes(tabAttributes, for: .selected)
        }
      }
      node.subviews.forEach(update)
    }
    if let window = view.window { update(window) }
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
