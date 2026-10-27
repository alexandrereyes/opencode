import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppTextStyle: CaseIterable, Sendable {
  case largeTitle, title, heading, body, message, preview, secondary, caption, footnote, micro
  case path, navigation, chrome, bubbleMeta, mcp, metrics

  var size: CGFloat {
    #if os(macOS)
    // The Mac reads the same roles at desktop density, about two points below the iPhone's text.
    switch self {
    case .largeTitle: 28
    case .title: 18
    case .heading, .body, .message, .navigation: 14
    case .preview, .secondary: 13
    case .caption, .path: 12
    case .footnote, .chrome, .bubbleMeta: 11
    case .micro, .mcp, .metrics: 10
    }
    #else
    switch self {
    case .largeTitle: 34
    case .title: 20
    case .heading, .body, .message, .navigation: 17
    case .preview, .secondary: 15
    case .caption, .path: 13
    case .footnote, .chrome, .bubbleMeta: 12
    case .micro, .mcp: 11
    case .metrics: 11
    }
    #endif
  }

  var lineHeight: CGFloat {
    switch self {
    case .body, .message: 22.5
    default: size * 1.3
    }
  }

  var maximumSize: CGFloat? {
    switch self {
    case .navigation, .chrome, .bubbleMeta, .mcp, .metrics: size
    default: nil
    }
  }

  var relativeTo: Font.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title2
    case .heading, .navigation: .headline
    case .body, .message: .body
    case .preview: .callout
    case .secondary: .subheadline
    case .caption, .path: .footnote
    case .footnote, .chrome, .bubbleMeta: .caption
    case .micro, .mcp, .metrics: .caption2
    }
  }

  #if os(iOS)
  var uiStyle: UIFont.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title2
    case .heading, .navigation: .headline
    case .body, .message: .body
    case .preview: .callout
    case .secondary: .subheadline
    case .caption, .path: .footnote
    case .footnote, .chrome, .bubbleMeta: .caption1
    case .micro, .mcp, .metrics: .caption2
    }
  }
  #endif
}

#if os(iOS)
@MainActor enum AppTypography {
  static func font(_ style: AppTextStyle, weight: UIFont.Weight = .regular,
    monospaced: Bool = false, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    let base = monospaced
      ? UIFont.monospacedSystemFont(ofSize: style.size, weight: weight)
      : UIFont.systemFont(ofSize: style.size, weight: weight)
    return UIFontMetrics(forTextStyle: style.uiStyle).scaledFont(for: base,
      maximumPointSize: style.maximumSize ?? .greatestFiniteMagnitude, compatibleWith: traits)
  }

  static func lineHeight(_ style: AppTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
    let height = UIFontMetrics(forTextStyle: style.uiStyle).scaledValue(for: style.lineHeight, compatibleWith: traits)
    return style.maximumSize == nil ? height : min(height, style.lineHeight)
  }
}

extension DynamicTypeSize {
  var uiCategory: UIContentSizeCategory {
    switch self {
    case .xSmall: .extraSmall
    case .small: .small
    case .medium: .medium
    case .large: .large
    case .xLarge: .extraLarge
    case .xxLarge: .extraExtraLarge
    case .xxxLarge: .extraExtraExtraLarge
    case .accessibility1: .accessibilityMedium
    case .accessibility2: .accessibilityLarge
    case .accessibility3: .accessibilityExtraLarge
    case .accessibility4: .accessibilityExtraExtraLarge
    case .accessibility5: .accessibilityExtraExtraExtraLarge
    default: .large
    }
  }
}
#endif

private struct AppFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  let weight: Font.Weight
  let design: Font.Design
  let maximumSize: CGFloat?

  init(_ style: AppTextStyle, weight: Font.Weight, design: Font.Design) {
    _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    self.weight = weight
    self.design = design
    maximumSize = style.maximumSize
  }

  func body(content: Content) -> some View {
    content.font(.system(size: min(size, maximumSize ?? .greatestFiniteMagnitude), weight: weight, design: design))
  }
}

extension View {
  func appFont(_ style: AppTextStyle, weight: Font.Weight = .regular,
    design: Font.Design = .default) -> some View {
    modifier(AppFont(style, weight: weight, design: design))
  }
}

enum AppLayout {
  static let margin: CGFloat = 16
  static let composerMargin: CGFloat = 12
  static let avatar: CGFloat = 44
  static let compactAvatar: CGFloat = 36
  static let avatarGap: CGFloat = 12
  static let rowTextInset = avatar + avatarGap
  static let compactRowTextInset = compactAvatar + avatarGap
}

enum AppSymbolSize: CGFloat {
  case inline = 13, disclosure = 12, action = 18, navigation = 20, header = 22, tab = 24
}

extension View {
  func appSymbol(_ size: AppSymbolSize, weight: Font.Weight = .medium) -> some View {
    font(.system(size: size.rawValue, weight: weight))
  }
}
