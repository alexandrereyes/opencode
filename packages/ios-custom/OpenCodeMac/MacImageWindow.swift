import AppKit
import SwiftUI

/// An image from the conversation in its own resizable window rather than a sheet (a sheet cannot be resized by the
/// user nor grow past its window). It opens at the image's size in points, at most 90% of the visible screen,
/// scaled to fit with its proportions. ⌘C (or the right-click menu) copies it, it drags out as a PNG, and Esc or a
/// click outside (the window stops being key) closes it, like the modals.
@MainActor final class MacImageWindow: NSObject, NSWindowDelegate {
  private static var open: Set<MacImageWindow> = []
  private let window: NSWindow
  private let parent: NSWindow?
  private var resized = false

  static func show(_ image: MacViewedImage, theme: AppTheme, over parent: NSWindow?) {
    let viewer = MacImageWindow(image: image, theme: theme, parent: parent)
    open.insert(viewer)
    viewer.window.makeKeyAndOrderFront(nil)
  }

  private init(image: MacViewedImage, theme: AppTheme, parent: NSWindow?) {
    window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    self.parent = parent
    super.init()
    window.title = image.name
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
    window.backgroundColor = theme.nsColor(.background)
    window.contentMinSize = NSSize(width: 320, height: 240)
    window.delegate = self
    let host = NSHostingController(rootView: MacImageViewer(image: image, close: { [weak window] in window?.close() }) {
      [weak self] original in
      guard let self, !self.resized else { return }
      self.place(original)
    }
    .environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR")))
    host.sizingOptions = []
    window.contentViewController = host
    place(image.image)
  }

  func windowDidEndLiveResize(_ notification: Notification) { resized = true }
  func windowDidResignKey(_ notification: Notification) { window.close() }
  func windowWillClose(_ notification: Notification) { Self.open.remove(self) }

  /// The image's size in points on the parent's screen, shrunk to fit 90% of its visible area, centered on the
  /// parent window.
  private func place(_ image: CGImage) {
    let screen = parent?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let scale = screen?.backingScaleFactor ?? 2
    let chrome = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100)).height - 100
      + MacImageViewer.header
    let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let fit = min(1, visible.width * 0.9 / max(1, natural.width), (visible.height * 0.9 - chrome) / max(1, natural.height))
    let content = NSSize(width: max(window.contentMinSize.width, (natural.width * fit).rounded()),
      height: max(window.contentMinSize.height, (natural.height * fit).rounded() + MacImageViewer.header))
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
    let anchor = parent?.frame ?? visible
    frame.origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.midY - frame.height / 2)
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
    window.setFrame(frame, display: true, animate: window.isVisible)
  }
}

private struct MacImageViewer: View {
  static let header: CGFloat = 44
  @Environment(\.appTheme) private var theme
  let image: MacViewedImage
  let close: () -> Void
  let loaded: (CGImage) -> Void
  @State private var original: CGImage?
  private var shown: CGImage { original ?? image.image }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button("Copiar imagem", systemImage: "doc.on.doc") { MacImageTransfer.copy(shown) }
          .shortcut(.copyImage)
          .help("Copiar imagem (⌘C)")
        Button("Fechar", action: close).keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 12).frame(height: Self.header)
      Image(decorative: shown, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrag { MacImageTransfer.provider(shown, name: image.name) }
        .contextMenu { MacImageMenu(image: shown) }
        .accessibilityLabel(image.name)
    }
    .background(theme.color(.background))
    .task {
      guard let value = await image.original?() else { return }
      original = value
      if value.width != image.image.width || value.height != image.image.height { loaded(value) }
    }
  }
}
