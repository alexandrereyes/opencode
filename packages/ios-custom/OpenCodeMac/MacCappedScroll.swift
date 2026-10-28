import AppKit
import SwiftUI

/// Measures the complete prompt at its real width, then caps only the native scroll viewport.
/// Unlike a clipped Text frame, all lines remain reachable; attachments and metadata are sibling views.
struct MacCappedScroll<Content: View>: NSViewRepresentable {
  @Environment(\.appTheme) private var theme
  let maxHeight: CGFloat
  @ViewBuilder let content: Content

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.verticalScroller = MacThinScroller()
    // Overlay even with "always show": the bubble's text is measured at the full width of this nested viewport.
    scroll.scrollerStyle = .overlay
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = context.coordinator.host.view
    scroll.setAccessibilityIdentifier("user-bubble-scroll")
    return scroll
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.host.rootView = AnyView(content.environment(\.appTheme, theme))
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    let height = context.coordinator.host.sizeThatFits(in: CGSize(width: width, height: .infinity)).height
    context.coordinator.host.view.frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
    return CGSize(width: width, height: min(ceil(height), max(1, maxHeight)))
  }
  @MainActor final class Coordinator {
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    init() { host.sizingOptions = [] }
  }
}
