import AppKit
import SwiftUI

/// The real NSWindow identifies the front conversation for notifications; no global selection or key-window guess.
struct MacWindowConnection: NSViewRepresentable {
  let runtime: MacWindowRuntime
  func makeNSView(context: Context) -> Connection { Connection(runtime: runtime) }
  func updateNSView(_ view: Connection, context: Context) {}

  final class Connection: NSView {
    let runtime: MacWindowRuntime
    init(runtime: MacWindowRuntime) { self.runtime = runtime; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      guard let window else { return }
      runtime.window = window
      if runtime.app.front == nil || window.isKeyWindow { runtime.app.front = runtime }
      NotificationCenter.default.addObserver(self, selector: #selector(front), name: NSWindow.didBecomeKeyNotification, object: window)
      NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSWindow.willCloseNotification, object: window)
      runtime.app.syncShown()
    }
    @objc private func front() {
      runtime.app.front = runtime
      runtime.app.syncShown()
    }
    @objc private func close() {
      runtime.app.windows[runtime.id] = nil
      if runtime.app.front === runtime { runtime.app.front = runtime.app.windows.values.first }
      runtime.close()
      runtime.app.syncShown()
    }
  }
}
