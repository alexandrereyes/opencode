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
  private static var capturingVoice = false

  /// The window at the approved mock's proportions, then the column. Launch options open what the capture shows:
  /// `-OpenCodeMacSelect id,id` (selection mode), `-OpenCodeMacNewSession sessoes|origem|mestra`,
  /// `-OpenCodeMacDetails` (Detalhes in Contexto), and in their own pictures
  /// `-OpenCodeMacOpenResource <id>` (`<name>-recurso.png`), `-OpenCodeMacShellOutput <shell>`
  /// (`<name>-saida.png`) and `-OpenCodeMacSettings <tab>` (`<name>-ajustes.png`). Sheets and popovers over the
  /// window are drawn into its picture.
  static func window(
    context: () -> ContextColumnStore?, runtime: MacWindowRuntime, theme: AppTheme, openWindow: OpenWindowAction,
    openSettings: OpenSettingsAction
  ) async {
    guard let folder, !MacStress.enabled else { return }
    if MacVoiceChecks.enabled {
      guard !capturingVoice else { return }
      capturingVoice = true
    }
    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.title != "LLM proxy" })
    else { return }
    if MacProxyLaunch.pane != nil {
      // The main window stays open behind the LLM proxy capture, off-screen like its own captures.
      window.setFrame(NSRect(x: -6000, y: 40, width: 1600, height: 1000), display: true)
      return
    }
    // An inactive window desaturates its glass tints; the capture shows the window as it looks in use. A
    // background test copy (`MacLaunch.background`) never takes the focus: its pictures show the inactive window.
    if !MacLaunch.background { NSApp.activate(ignoringOtherApps: true) }
    window.makeKeyAndOrderFront(nil)
    // Outside the visible screens, so a capture run never sits under Alexandre's pointer. The approved mocks
    // are a 1269×794-pt window drawn at 1.25×: `-OpenCodeMacCaptureSize 1269x794` matches them.
    let size = MacFixture.value("-OpenCodeMacCaptureSize")?.split(separator: "x").compactMap { Double($0) }
    window.setFrame(NSRect(x: -4000, y: 40, width: size?.first ?? 1600, height: size?.last ?? 1000), display: true)
    let delay = MacFixture.value("-OpenCodeMacCaptureDelay").flatMap(Double.init)
    try? await Task.sleep(for: .seconds(delay ?? (MacFixture.current == nil ? 8 : 4)))
    do { try await MacVoiceChecks.run(runtime, openWindow: openWindow) }
    catch { print("MacVoiceChecks failed: \(error)"); exit(1) }
    let extra = await open(runtime: runtime, context: context, openWindow: openWindow, openSettings: openSettings)
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacHideContext")
      || ProcessInfo.processInfo.arguments.contains("-OpenCodeMacHideSessions") {
      // The requested narrow size may have been clamped by the three-column minimum before they collapsed.
      window.setFrame(NSRect(x: -4000, y: 40, width: size?.first ?? 1600, height: size?.last ?? 1000), display: true)
    }
    try? await Task.sleep(for: .seconds(2))
    if let query = MacFixture.value("-OpenCodeMacModelPalette") {
      runtime.openModelPalette(theme: theme)
      runtime.modelPalette.state?.query = query == "empty" ? "" : query
      try? await Task.sleep(for: .milliseconds(300))
    }
    if runtime.search.visible, ProcessInfo.processInfo.arguments.contains("-OpenCodeMacSearchFixture"),
      let error = MacSearchChecks.geometry(runtime) {
      print("MacCapture busca: \(error)")
      exit(1)
    }
    await MacDetailsFixture.verify(window: window, runtime: runtime, theme: theme, folder: folder)
    await MacAjustesChecks.run(window: window, runtime: runtime, theme: theme, folder: folder)
    // `-OpenCodeMacCaptureEvery <s> -OpenCodeMacCaptureCount <n>`: a sequence (`<name>-01.png`…), a short video of
    // a live conversation, a stream or paging.
    if let every = MacFixture.value("-OpenCodeMacCaptureEvery").flatMap(Double.init),
      let count = MacFixture.value("-OpenCodeMacCaptureCount").flatMap(Int.init), count > 0
    {
      for index in 1...count {
        shot(window, theme: theme, to: folder + "/" + name + String(format: "-%02d.png", index))
        if index < count { try? await Task.sleep(for: .seconds(every)) }
      }
      if quits { exit(0) }
      return
    }
    shot(window, theme: theme, to: folder + "/" + name + ".png")
    if MacVoiceChecks.enabled {
      for other in runtime.app.windows.values where other !== runtime {
        if let window = other.window { shot(window, theme: theme, to: folder + "/" + name + "-second.png") }
      }
    }
    for (suffix, title) in extra {
      guard let other = NSApp.windows.first(where: { $0.isVisible && $0 !== window && title($0) }),
        let picture = (screenLocked ? nil : image(of: other)) ?? drawn(other),
        let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else { continue }
      try? png.write(to: URL(fileURLWithPath: folder + "/" + name + "-" + suffix + ".png"))
    }
    if let context = context(), runtime.selection.files == nil {
      column(context, runtime: runtime, theme: theme, to: folder + "/" + name + "-coluna.png")
    }
    // A sheet or popover still open would hold `terminate` back.
    if quits { exit(0) }
  }

  /// Opens what the launch options ask for and returns the separate windows to capture (suffix, match).
  private static func open(
    runtime: MacWindowRuntime, context: () -> ContextColumnStore?, openWindow: OpenWindowAction,
    openSettings: OpenSettingsAction
  ) async -> [(String, (NSWindow) -> Bool)] {
    var extra: [(String, (NSWindow) -> Bool)] = []
    if let ids = MacFixture.value("-OpenCodeMacSelect")?.split(separator: ",").map(String.init), let first = ids.first {
      runtime.sessionSelection.start(first)
      ids.dropFirst().forEach { runtime.sessionSelection.toggle($0) }
    }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacDetails") { context()?.detailsOpen = true }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacHideContext") { runtime.contextVisible = false }
    if ProcessInfo.processInfo.arguments.contains("-OpenCodeMacHideSessions") { runtime.columns = .detailOnly }
    if let query = MacFixture.value("-OpenCodeMacSearch") {
      runtime.search.query = query == "empty" ? "" : query
      runtime.search.open()
    }
    switch MacFixture.value("-OpenCodeMacNewSession") {
    case "sessoes": runtime.newSession()
    case "origem": runtime.newSession(from: MacFixture.rootID)
    case "mestra": runtime.newSessionRequest = MacNewSessionRequest(origin: nil, startInChats: false, master: true)
    default: break
    }
    if let id = MacFixture.value("-OpenCodeMacOpenResource") {
      openWindow(id: "resource", value: id)
      extra.append(("recurso", { $0.identifier?.rawValue.hasPrefix("resource") == true }))
    }
    if let shell = MacFixture.value("-OpenCodeMacShellOutput"), let directory = context()?.directory {
      openWindow(id: MacShellOutputWindow.id,
        value: MacShellOutputWindow.Target(shellID: shell, directory: directory, command: "bun run dev --port 4177"))
      extra.append(("saida", { $0.identifier?.rawValue.hasPrefix(MacShellOutputWindow.id) == true }))
    }
    // `-OpenCodeMacSideQuestion <question>`: Pergunta paralela about a passage, answered by the fixture.
    if let question = MacFixture.value("-OpenCodeMacSideQuestion") {
      runtime.askSideQuestion(quote: "Juízes do smoke: a skill usa juízes em paralelo.", text: question, submit: true)
    }
    if let tab = MacFixture.value("-OpenCodeMacSettings") {
      UserDefaults.standard.set(tab, forKey: "OpenCodeMacSettingsTab")
      openSettings()
      extra.append(("ajustes", { $0.identifier?.rawValue.contains("Settings") == true || $0.title == tabTitle(tab) }))
    }
    try? await Task.sleep(for: .seconds(2))
    // Off-screen like the main window, so a capture run never sits under Alexandre's pointer.
    for window in NSApp.windows where window.isVisible && window.attachedSheet == nil && window.sheetParent == nil
      && extra.contains(where: { $0.1(window) }) {
      window.setFrameOrigin(NSPoint(x: -3000, y: 60))
    }
    return extra
  }

  private static func tabTitle(_ tab: String) -> String {
    ["servidores": "Servidores", "aparencia": "Aparência", "leitura": "Leitura", "modelos": "Modelos",
     "assinaturas": "Assinaturas", "sobre": "Sobre"][tab] ?? tab
  }

  /// The window with its sheet and any popover over it, each drawn where it sits.
  private static func composed(_ window: NSWindow, theme: AppTheme) -> CGImage? {
    func draw(_ window: NSWindow) -> CGImage? { (screenLocked ? nil : image(of: window)) ?? drawn(window) }
    guard var base = draw(window) else { return nil }
    let overlays = NSApp.windows.filter { other in
      other !== window && other.isVisible
        && (other.sheetParent === window || String(describing: type(of: other)).contains("Popover")
          || (other.parent === window && ["mac-search-suggestions", "mac-model-palette", "mac-notification-panel", "mac-server-menu"].contains(other.identifier?.rawValue ?? ""))
          || (other.parent?.sheetParent === window && other.identifier?.rawValue == "mac-model-palette"))
    }.sorted { ($0.identifier?.rawValue == "mac-model-palette" ? 1 : 0) < ($1.identifier?.rawValue == "mac-model-palette" ? 1 : 0) }
    for other in overlays {
      guard let picture = draw(other) else { continue }
      if ["mac-search-suggestions", "mac-model-palette", "mac-notification-panel", "mac-server-menu"].contains(other.identifier?.rawValue ?? "") {
        base = compose(base, window, picture, other) ?? base
        continue
      }
      // AppKit keeps a popover on a screen while the window sits off-screen: draw it under the title instead.
      let popover = other.sheetParent == nil
      base = (popover ? place(base, window, picture, at: CGPoint(x: 420, y: 46), width: other.frame.width)
        : compose(base, window, picture, other)) ?? base
    }
    return base
  }

  /// The LLM proxy modal over the window (`-OpenCodeMacProxy codex|anthropic|resets`), off-screen at
  /// `-OpenCodeMacCaptureSize WxH` (1200×800 by default). `-OpenCodeMacProxyAction confirm|applying` asks to use
  /// a reset of `-OpenCodeMacProxyAccount` first: `confirm` leaves the dialog open (drawn over the window),
  /// `applying` confirms it at once against the fixture.
  static func proxy(runtime: MacRuntime, theme: AppTheme) async {
    guard let folder, MacProxyLaunch.pane != nil else { return }
    try? await Task.sleep(for: .milliseconds(500))
    guard let window = NSApp.windows.first(where: { $0.attachedSheet != nil && $0.canBecomeMain }) else { return }
    if !MacLaunch.background { NSApp.activate(ignoringOtherApps: true) }
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
    shot(window, theme: theme, to: folder + "/" + name + ".png")
    if quits { NSApp.terminate(nil) }
  }

  /// The window with its sheet and any popover over it (`composed`), as a PNG.
  static func shot(_ window: NSWindow, theme: AppTheme, to path: String) {
    if screenLocked, let view = window.contentView?.superview ?? window.contentView {
      unglaze(view, background: theme.nsColor(.background))
    }
    guard let picture = composed(window, theme: theme),
      let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
  }

  /// While the screen is locked the window server returns blank pictures of every window.
  private static var screenLocked: Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
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

  /// `picture` at `point` (window points from the top left).
  private static func place(_ base: CGImage, _ window: NSWindow, _ picture: CGImage, at point: CGPoint, width: Double)
    -> CGImage? {
    let scale = Double(base.width) / window.frame.width
    let height = Double(picture.height) * width * scale / Double(picture.width)
    guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
    context.draw(picture, in: CGRect(x: point.x * scale, y: Double(base.height) - point.y * scale - height,
      width: width * scale, height: height))
    return context.makeImage()
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
  private static func column(_ store: ContextColumnStore, runtime: MacWindowRuntime, theme: AppTheme, to path: String) {
    let content = ContextColumnSections(store: store, runtime: runtime)
      .padding(.horizontal, 18).padding(.vertical, 12)
      .frame(width: 430)
      .background(theme.color(.background))
      .environment(\.appTheme, theme)
      .environment(\.locale, Locale(identifier: "pt_BR"))
      .environment(\.colorScheme, theme.dark ? .dark : .light)
      .environment(\.macStillCapture, true)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
  }
}
#endif
