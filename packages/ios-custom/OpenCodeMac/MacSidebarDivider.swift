import AppKit
import SwiftUI

/// Extends the sidebar hairline through the unified title bar. It follows the actual split geometry, without
/// adding constraints or changing the native divider's drag/hit area.
struct MacSidebarDivider: NSViewRepresentable {
  @Environment(\.appTheme) private var theme
  let visible: Bool

  func makeNSView(context: Context) -> Probe { Probe() }
  func updateNSView(_ view: Probe, context: Context) {
    view.line.layer?.backgroundColor = theme.nsColor(.border).cgColor
    view.line.isHidden = !visible
    view.schedule()
  }
  static func dismantleNSView(_ view: Probe, coordinator: ()) {
    view.line.removeFromSuperview()
    NotificationCenter.default.removeObserver(view)
  }

  final class Hairline: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  final class Probe: NSView {
    let line = Hairline()
    override init(frame: NSRect) {
      super.init(frame: frame)
      line.wantsLayer = true
      line.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      line.removeFromSuperview()
      NotificationCenter.default.removeObserver(self)
      guard let window, let root = window.contentView?.superview else { return }
      root.addSubview(line, positioned: .above, relativeTo: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: NSSplitView.didResizeSubviewsNotification, object: nil)
      NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged), name: NSWindow.didResizeNotification, object: window)
      schedule()
    }
    override func layout() { super.layout(); schedule() }
    @objc private func geometryChanged(_ notification: Notification) {
      if let split = notification.object as? NSSplitView, split.window !== window { return }
      schedule()
    }
    func schedule() {
      DispatchQueue.main.async { [weak self] in
        guard let self, let root = self.line.superview else { return }
        let edge = self.convert(self.bounds, to: root).maxX
        self.line.frame = NSRect(x: edge - 1, y: 0, width: 1, height: root.bounds.height)
      }
    }
  }
}
