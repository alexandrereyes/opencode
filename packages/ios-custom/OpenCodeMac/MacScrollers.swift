import AppKit
import SwiftUI

/// The app's scroll bars: half the system's thickness, no track and a low-contrast knob. The style still follows
/// Ajustes do Sistema ▸ Aparência ▸ "Mostrar barras de rolagem": NSScrollView keeps choosing overlay scrollers
/// (shown while scrolling, then faded by AppKit) or legacy ones (always shown), and this class only draws them.
final class MacThinScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }

  override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
    (super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle) / 2).rounded()
  }

  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

  override func drawKnob() {
    let knob = rect(for: .knob)
    let vertical = knob.height >= knob.width
    let thickness = max(3, (vertical ? bounds.width : bounds.height) - 3)
    let rect = vertical
      ? CGRect(x: knob.midX - thickness / 2, y: knob.minY + 1, width: thickness, height: max(0, knob.height - 2))
      : CGRect(x: knob.minX + 1, y: knob.midY - thickness / 2, width: max(0, knob.width - 2), height: thickness)
    // `labelColor` follows light and dark; a hover or drag brings it up a little.
    NSColor.labelColor.withAlphaComponent(hitPart == .knob ? 0.38 : 0.22).setFill()
    NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
  }
}

extension NSScrollView {
  /// Gives this scroll view the app's thin scroll bars (once).
  func adoptThinScrollers() {
    guard !(verticalScroller is MacThinScroller) else { return }
    verticalScroller = MacThinScroller()
    if hasHorizontalScroller { horizontalScroller = MacThinScroller() }
    tile()
  }
}

extension View {
  /// Gives the SwiftUI scroll view (or `List`) around this content the app's thin scroll bars. Put it on content
  /// inside the scroll view: it finds its enclosing NSScrollView once it is in a window.
  func macThinScrollers() -> some View { background(MacScrollerInstaller()) }
}

private struct MacScrollerInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {}

  final class Probe: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      // The hosting scroll view is attached during the same pass; look it up on the next turn.
      DispatchQueue.main.async { [weak self] in self?.enclosingScrollView?.adoptThinScrollers() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
