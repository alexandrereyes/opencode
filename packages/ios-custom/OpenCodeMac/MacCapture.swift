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
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.title != "LLM proxy" })
    else { return }
    if MacProxyLaunch.pane != nil {
      // The main window stays open behind the LLM proxy capture, off-screen like its own captures.
      window.setFrame(NSRect(x: -6000, y: 40, width: 1600, height: 1000), display: true)
      return
    }
    // An inactive window desaturates its glass tints; the capture shows the window as it looks in use.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    // Outside the visible screens, so a capture run never sits under Alexandre's pointer. The approved mocks
    // are a 1269×794-pt window drawn at 1.25×: `-OpenCodeMacCaptureSize 1269x794` matches them.
    let size = MacFixture.value("-OpenCodeMacCaptureSize")?.split(separator: "x").compactMap { Double($0) }
    window.setFrame(NSRect(x: -4000, y: 40, width: size?.first ?? 1600, height: size?.last ?? 1000), display: true)
    try? await Task.sleep(for: .seconds(MacFixture.current == nil ? 8 : 5))
    let path = folder + "/" + name + ".png"
    if screenLocked || !windowServerImage(window, to: path), let view = window.contentView?.superview ?? window.contentView {
      if screenLocked { unglaze(view, background: theme.nsColor(.background)) }
      cached(view, to: path)
    }
    if let context = context(), runtime.selection.files == nil {
      column(context, runtime: runtime, theme: theme, to: folder + "/" + name + "-coluna.png")
    }
    if quits { NSApp.terminate(nil) }
  }

  /// The LLM proxy window (`-OpenCodeMacProxy codex|anthropic|resets`), off-screen at
  /// `-OpenCodeMacCaptureSize WxH` (1200×800 by default). `-OpenCodeMacProxyAction confirm|applying` asks to use
  /// a reset of `-OpenCodeMacProxyAccount` first: `confirm` leaves the dialog open (drawn over the window),
  /// `applying` confirms it at once against the fixture.
  static func proxy(runtime: MacRuntime, theme: AppTheme) async {
    guard let folder, MacProxyLaunch.pane != nil else { return }
    try? await Task.sleep(for: .milliseconds(500))
    guard let window = NSApp.windows.first(where: { $0.title == "LLM proxy" }) else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    let size = MacFixture.value("-OpenCodeMacCaptureSize")?.split(separator: "x").compactMap { Double($0) }
    let frame = NSRect(x: -4000, y: 40, width: size?.first ?? 1200, height: size?.last ?? 800)
    window.setFrame(frame, display: true)
    try? await Task.sleep(for: .seconds(1))
    window.setFrame(frame, display: true)
    try? await Task.sleep(for: .seconds(2))
    if let action = MacFixture.value("-OpenCodeMacProxyAction"), let store = runtime.store?.quota,
      case .provider(let provider) = runtime.proxyPane ?? .provider(.codex),
      let account = store.snapshot?.pool(provider).accounts.first(where: { $0.id == MacProxyLaunch.account }) {
      // Same main-actor turn: `confirm()` clears the request before SwiftUI can present the dialog.
      Task { @MainActor in
        store.requestReset(provider, account: account)
        if action == "applying" { await store.confirm() }
      }
      try? await Task.sleep(for: .seconds(1.5))
    }
    let sidebar = runtime.store.map { store in
      VStack(alignment: .leading, spacing: 14) { MacProxySidebar(store: store.quota, runtime: runtime) }
        .padding(.horizontal, 16).frame(width: 230, alignment: .topLeading)
        .environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR"))
        .environment(\.colorScheme, theme.dark ? .dark : .light)
    }
    if let picture = picture(window, sidebar: sidebar),
      let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) {
      try? png.write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
    }
    if quits { NSApp.terminate(nil) }
  }

  /// The window with an attached sheet (a dialog) drawn over it. While the screen is locked the window server
  /// hands back blank pictures, so AppKit draws the views instead; it cannot draw the Liquid Glass sidebar, so
  /// the sidebar's own rows are rendered over that column.
  private static func picture(_ window: NSWindow, sidebar: (some View)?) -> CGImage? {
    let locked = screenLocked
    func draw(_ window: NSWindow) -> CGImage? { (locked ? nil : image(of: window)) ?? drawn(window) }
    guard var base = draw(window) else { return nil }
    if locked, let sidebar, let column = sidebarColumn(window) {
      let renderer = ImageRenderer(content: sidebar)
      renderer.scale = Double(base.width) / window.frame.width
      if let rows = renderer.cgImage { base = overlay(base, window, rows, column) ?? base }
    }
    return window.attachedSheet.flatMap { sheet in draw(sheet).flatMap { compose(base, window, $0, sheet) } } ?? base
  }

  /// While the screen is locked the window server returns blank pictures of every window.
  private static var screenLocked: Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
  }

  /// The split view's first column, in window coordinates.
  private static func sidebarColumn(_ window: NSWindow) -> NSRect? {
    func find(_ view: NSView) -> NSSplitView? {
      if let split = view as? NSSplitView { return split }
      return view.subviews.lazy.compactMap(find).first
    }
    guard let root = window.contentView?.superview ?? window.contentView, let split = find(root),
      let column = split.arrangedSubviews.first else { return nil }
    return column.convert(column.bounds, to: nil)
  }

  /// Fills the blank column with the window background and draws the rows below the title bar.
  private static func overlay(_ base: CGImage, _ window: NSWindow, _ rows: CGImage, _ column: NSRect) -> CGImage? {
    let scale = Double(base.width) / window.frame.width
    guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    let titleBar = 52.0
    let area = CGRect(x: column.minX * scale, y: column.minY * scale, width: column.width * scale,
      height: (column.height - titleBar) * scale)
    context.setFillColor(NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(gray: 0.12, alpha: 1))
    context.fill(area)
    context.draw(rows, in: CGRect(x: area.minX + (area.width - Double(rows.width)) / 2,
      y: area.maxY - Double(rows.height) - 8 * scale, width: Double(rows.width), height: Double(rows.height)))
    return context.makeImage()
  }

  private static func drawn(_ window: NSWindow) -> CGImage? {
    guard let view = window.contentView?.superview ?? window.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.cgImage
  }

  /// `CGWindowListCreateImage`, looked up at run time because the macOS 15 SDK hides it in favor of
  /// ScreenCaptureKit, which always asks for permission.
  private static func windowServerImage(_ window: NSWindow, to path: String) -> Bool {
    guard let image = image(of: window),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }

  private static func image(of window: NSWindow) -> CGImage? {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let capture = unsafeBitCast(symbol, to: Capture.self)
    // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
    guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
      image.width > 100 else { return nil }
    return image
  }

  private static func compose(_ base: CGImage, _ window: NSWindow, _ sheet: CGImage, _ sheetWindow: NSWindow) -> CGImage? {
    let scale = Double(base.width) / window.frame.width
    guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    let x = (sheetWindow.frame.minX - window.frame.minX) * scale
    let y = (sheetWindow.frame.minY - window.frame.minY) * scale
    context.draw(sheet, in: CGRect(x: x, y: y, width: Double(sheet.width), height: Double(sheet.height)))
    return context.makeImage()
  }

  private static func cached(_ view: NSView, to path: String) {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  /// AppKit cannot draw the Liquid Glass sidebar (`NSGlassEffectView`): the column's SwiftUI background lives in
  /// the glass and comes out white, under light text. A locked-screen capture gives the sidebar's list views an
  /// AppKit background of the theme's color instead; capture runs quit right after.
  private static func unglaze(_ root: NSView, background: NSColor) {
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    for glass in all(root) where String(describing: type(of: glass)) == "NSGlassEffectView" {
      for view in all(glass) {
        if let scroll = view as? NSScrollView {
          scroll.drawsBackground = true
          scroll.backgroundColor = background
          (scroll.contentView as NSClipView).drawsBackground = true
          scroll.contentView.backgroundColor = background
        }
        if let table = view as? NSTableView { table.backgroundColor = background }
      }
      glass.superview?.wantsLayer = true
      glass.superview?.layer?.backgroundColor = background.cgColor
    }
    root.display()
  }

  /// The column unscrolled, at its default width.
  private static func column(_ store: ContextColumnStore, runtime: MacRuntime, theme: AppTheme, to path: String) {
    let content = ContextColumnSections(store: store, runtime: runtime)
      .padding(.horizontal, 18).padding(.vertical, 12)
      .frame(width: 430)
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
