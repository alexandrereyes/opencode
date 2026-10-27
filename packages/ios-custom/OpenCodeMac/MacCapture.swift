#if DEBUG
import AppKit
import OpenCodeKit
import SwiftUI

/// Captures for review without Screen Recording permission (`screencapture` needs it):
/// - the window, from the window server's picture of this app's own window (no permission needed for it),
///   falling back to `cacheDisplay`, which cannot draw the Liquid Glass sidebar;
/// - the Contexto column at full height, unscrolled, through `ImageRenderer`.
///
/// `-OpenCodeMacCapture <folder> -OpenCodeMacCaptureName <name> [-OpenCodeMacCaptureQuit]`
@MainActor enum MacCapture {
  static let folder = MacFixture.value("-OpenCodeMacCapture")
  static let name = MacFixture.value("-OpenCodeMacCaptureName") ?? "janela"
  static let quits = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacCaptureQuit")

  /// The window at the approved mock's proportions, then the column.
  static func window(context: () -> ContextColumnStore?, runtime: MacRuntime, theme: AppTheme) async {
    guard let folder else { return }
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
    // An inactive window desaturates its glass tints; the capture shows the window as it looks in use.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    // Outside the visible screens, so a capture run never sits under Alexandre's pointer.
    window.setFrame(NSRect(x: -4000, y: 40, width: 1600, height: 1000), display: true)
    try? await Task.sleep(for: .seconds(MacFixture.current == nil ? 8 : 5))
    let path = folder + "/" + name + ".png"
    if !windowServerImage(window, to: path), let view = window.contentView?.superview ?? window.contentView {
      cached(view, to: path)
    }
    if let context = context(), runtime.selection.files == nil {
      column(context, runtime: runtime, theme: theme, to: folder + "/" + name + "-coluna.png")
    }
    if quits { NSApp.terminate(nil) }
  }

  /// `CGWindowListCreateImage`, looked up at run time because the macOS 15 SDK hides it in favor of
  /// ScreenCaptureKit, which always asks for permission.
  private static func windowServerImage(_ window: NSWindow, to path: String) -> Bool {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
    let capture = unsafeBitCast(symbol, to: Capture.self)
    // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
    guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
      image.width > 100, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  private static func cached(_ view: NSView, to path: String) {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  /// The column's cards unscrolled, at the inspector's width, like the approved `contexto.png`.
  private static func column(_ store: ContextColumnStore, runtime: MacRuntime, theme: AppTheme, to path: String) {
    let content = ContextColumnCards(store: store, runtime: runtime)
      .padding(12)
      .frame(width: 512)
      .background(theme.color(.background))
      .environment(\.appTheme, theme)
      .environment(\.locale, Locale(identifier: "pt_BR"))
      .environment(\.colorScheme, theme.dark ? .dark : .light)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
  }
}
#endif
