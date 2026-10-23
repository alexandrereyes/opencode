import SwiftUI
import UIKit

enum AppTextStyle: CaseIterable, Sendable {
  case largeTitle, title, heading, body, message, preview, secondary, caption, footnote, micro

  var size: CGFloat {
    switch self {
    case .largeTitle: 37
    case .title: 22
    case .heading, .body: 18.5
    case .message: 17.5
    case .preview: 16.5
    case .secondary: 15.25
    case .caption: 14.25
    case .footnote: 13.25
    case .micro: 11.5
    }
  }

  var lineHeight: CGFloat {
    switch self {
    case .body: 28.5
    case .message: 24
    default: size * 1.3
    }
  }

  var relativeTo: Font.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title2
    case .heading: .headline
    case .body, .message: .body
    case .preview: .callout
    case .secondary: .subheadline
    case .caption: .footnote
    case .footnote: .caption
    case .micro: .caption2
    }
  }

  var uiStyle: UIFont.TextStyle {
    switch self {
    case .largeTitle: .largeTitle
    case .title: .title2
    case .heading: .headline
    case .body, .message: .body
    case .preview: .callout
    case .secondary: .subheadline
    case .caption: .footnote
    case .footnote: .caption1
    case .micro: .caption2
    }
  }
}

@MainActor enum AppTypography {
  static func font(_ style: AppTextStyle, weight: UIFont.Weight = .regular,
    monospaced: Bool = false, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
    let base = monospaced
      ? UIFont.monospacedSystemFont(ofSize: style.size, weight: weight)
      : UIFont.systemFont(ofSize: style.size, weight: weight)
    return UIFontMetrics(forTextStyle: style.uiStyle).scaledFont(for: base, compatibleWith: traits)
  }

  static func lineHeight(_ style: AppTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
    UIFontMetrics(forTextStyle: style.uiStyle).scaledValue(for: style.lineHeight, compatibleWith: traits)
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

private struct AppFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  let weight: Font.Weight
  let design: Font.Design

  init(_ style: AppTextStyle, weight: Font.Weight, design: Font.Design) {
    _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    self.weight = weight
    self.design = design
  }

  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: weight, design: design))
  }
}

extension View {
  func appFont(_ style: AppTextStyle, weight: Font.Weight = .regular,
    design: Font.Design = .default) -> some View {
    modifier(AppFont(style, weight: weight, design: design))
  }
}

enum AppLayout {
  static let margin: CGFloat = 20
  static let avatar: CGFloat = 48
  static let avatarGap: CGFloat = 12
  static let rowTextInset = avatar + avatarGap
}

enum AppSymbolSize: CGFloat {
  case inline = 13, disclosure = 12, action = 18, navigation = 20, header = 22, tab = 24
}

extension View {
  func appSymbol(_ size: AppSymbolSize, weight: Font.Weight = .medium) -> some View {
    font(.system(size: size.rawValue, weight: weight))
  }
}
