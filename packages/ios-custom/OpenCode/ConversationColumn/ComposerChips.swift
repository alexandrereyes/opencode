import SwiftUI

/// The subtle capsule of the composer's control chips: the model and `● MCP · 1/4 ⌄` share it.
struct ComposerCapsule: ViewModifier {
  @Environment(\.appTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  var horizontal: CGFloat = 6

  func body(content: Content) -> some View {
    content.padding(.horizontal, horizontal).frame(height: 20)
      .adaptiveGlass(Capsule(), interactive: true)
      .overlay { Capsule().strokeBorder(theme.color(.controlBorder), lineWidth: 1 / displayScale) }
  }
}

/// `Opus 5.5 · xhigh` inside the composer's capsule; tapping opens the model and effort picker. The tap
/// target keeps the control row's height.
struct ComposerModelChip: View {
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label).appFont(.chrome).lineLimit(1).minimumScaleFactor(0.75)
        .composerCapsule(horizontal: 8)
        .frame(minHeight: 36).contentShape(Rectangle())
    }
  }
}

extension View {
  func composerCapsule(horizontal: CGFloat = 6) -> some View { modifier(ComposerCapsule(horizontal: horizontal)) }
}
