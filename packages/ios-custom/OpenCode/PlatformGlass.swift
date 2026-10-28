import SwiftUI

/// Liquid Glass for views shared with the Mac app, which still runs on macOS 15: there the same shape gets a
/// material (or its tint) instead. iOS always takes the glass branch.
extension View {
  @ViewBuilder func adaptiveGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
    #if os(macOS)
    if #available(macOS 26, *) {
      glassEffect(glass(tint: tint, interactive: interactive), in: shape)
    } else if let tint {
      background(tint, in: shape)
    } else {
      background(.regularMaterial, in: shape)
    }
    #else
    glassEffect(glass(tint: tint, interactive: interactive), in: shape)
    #endif
  }
}

@available(macOS 26, *)
private func glass(tint: Color?, interactive: Bool) -> Glass {
  let glass = tint.map { Glass.regular.tint($0) } ?? .regular
  return interactive ? glass.interactive() : glass
}

/// `GlassEffectContainer` where it exists, so neighboring glass shapes blend; a plain group on macOS 15.
struct AdaptiveGlassContainer<Content: View>: View {
  var spacing: CGFloat? = nil
  @ViewBuilder let content: Content
  var body: some View {
    #if os(macOS)
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
    #else
    GlassEffectContainer(spacing: spacing) { content }
    #endif
  }
}

extension View {
  /// The glass button styles, bordered on macOS 15.
  @ViewBuilder func adaptiveGlassButtonStyle(prominent: Bool = false) -> some View {
    #if os(macOS)
    if #available(macOS 26, *) {
      if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    } else if prominent {
      buttonStyle(.borderedProminent)
    } else {
      buttonStyle(.bordered)
    }
    #else
    if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    #endif
  }
}

extension View {
  /// A borderless menu on macOS (AppKit draws a pop-up button otherwise); unchanged on iOS.
  @ViewBuilder func plainMenuOnMac() -> some View {
    #if os(macOS)
    menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    #else
    self
    #endif
  }
}
