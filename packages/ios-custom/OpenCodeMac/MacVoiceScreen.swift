import AppKit
import OpenCodeKit
@preconcurrency import ScreenCaptureKit

/// What the voice screen capture reads from the Mac; a fake stands in for checks that must not touch TCC.
@MainActor protocol MacScreenSystem: AnyObject {
  var ownPID: Int32 { get }
  var frontPID: Int32? { get }
  var apps: [VoiceScreenPlanner.App] { get }
  /// On-screen windows, front to back. Titles appear only with Screen Recording permission.
  var windows: [VoiceScreenWindow] { get }
  var displays: [VoiceScreenPlanner.Display] { get }
  /// `CGPreflightScreenCaptureAccess`: never prompts.
  var permission: Bool { get }
  /// Whether OpenCode already asked macOS once; it never asks again.
  var asked: Bool { get set }
  func requestPermission()
  /// OpenCode's window in front of its others, and the conversation it shows.
  var ownWindow: (window: NSWindow, sessionID: String?)? { get }
  func capture(own window: NSWindow) -> CGImage?
  func capture(_ source: VoiceScreenSource) async throws(VoiceScreenRefusal) -> CGImage
}

/// The Mac side of `"screen"` delegations: plan with `VoiceScreenPlanner`, capture, encode as the iPhone does.
@MainActor enum MacVoiceScreen {
  static var system: any MacScreenSystem = MacScreenLive()
  static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

  static func capture(_ target: VoiceScreenTarget) async throws(VoiceScreenRefusal) -> VoiceScreenShot {
    let system = system
    let own = system.ownWindow
    let plan = try VoiceScreenPlanner.plan(target, own: system.ownPID, front: system.frontPID, apps: system.apps,
      windows: system.windows, displays: system.displays, permission: system.permission, asked: system.asked,
      ownWindow: own != nil)
    if plan.requestsPermission {
      system.asked = true
      system.requestPermission()
    }
    // As on the iPhone, the voice bar and toasts leave OpenCode's window for the frame being captured.
    let veil = VoiceCaptureVeil.shared
    veil.hide(true)
    defer { veil.hide(false) }
    try? await Task.sleep(for: .milliseconds(80))
    let image: CGImage
    if plan.source == .own {
      guard let own, let picture = system.capture(own: own.window) else { throw .failed }
      image = picture
    } else {
      image = try await system.capture(plan.source)
    }
    return VoiceScreenShot(jpeg: try jpeg(image), sessionID: plan.source == .own ? own?.sessionID : nil,
      subject: VoiceScreenPlanner.subject(plan.source), notice: plan.notice)
  }

  /// At most 2000 px on the longer side (the server's image limit, which would otherwise re-encode it as a
  /// larger PNG), JPEG 0.72 like the iPhone's capture.
  static func jpeg(_ image: CGImage) throws(VoiceScreenRefusal) -> Data {
    let scale = min(1, 2000 / Double(max(image.width, image.height)))
    let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw .failed }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    else { throw .failed }
    return data
  }

  /// The window server's picture of one of OpenCode's own windows: allowed without Screen Recording.
  /// `CGWindowListCreateImage` is looked up at run time; the macOS 15 SDK hides it in favor of ScreenCaptureKit,
  /// which asks for permission even for the app's own windows.
  static func ownImage(_ window: NSWindow) -> CGImage? {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
      // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution.
      let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?
        .takeRetainedValue(), image.width > 100 {
      return image
    }
    // AppKit's own drawing, without Liquid Glass, when the window server gives nothing.
    guard let view = window.contentView?.superview ?? window.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.cgImage
  }
}

@MainActor final class MacScreenLive: MacScreenSystem {
  private static let askedKey = "OpenCodeVoiceScreenPermissionAsked"
  var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }
  var frontPID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
  var apps: [VoiceScreenPlanner.App] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
      .compactMap { app in app.localizedName.map { VoiceScreenPlanner.App(pid: app.processIdentifier, name: $0) } }
  }
  var windows: [VoiceScreenWindow] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    return list.compactMap { info in
      guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
      return VoiceScreenWindow(id: id, pid: pid, app: info[kCGWindowOwnerName as String] as? String ?? "",
        title: info[kCGWindowName as String] as? String, frame: frame, layer: info[kCGWindowLayer as String] as? Int ?? 0)
    }
  }
  var displays: [VoiceScreenPlanner.Display] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let main = CGMainDisplayID()
    return ids.sorted { ($0 == main ? 0 : 1) < ($1 == main ? 0 : 1) }
      .map { VoiceScreenPlanner.Display(id: $0, frame: CGDisplayBounds($0)) }
  }
  var permission: Bool { CGPreflightScreenCaptureAccess() }
  var asked: Bool {
    get { UserDefaults.standard.bool(forKey: Self.askedKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.askedKey) }
  }
  func requestPermission() { _ = CGRequestScreenCaptureAccess() }
  var ownWindow: (window: NSWindow, sessionID: String?)? {
    let runtime = MacRuntime.shared.front
    guard let window = runtime?.window ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return nil }
    return (window, runtime.flatMap { $0.selection.childID ?? $0.selection.sessionID })
  }
  func capture(own window: NSWindow) -> CGImage? { MacVoiceScreen.ownImage(window) }

  func capture(_ source: VoiceScreenSource) async throws(VoiceScreenRefusal) -> CGImage {
    let content: SCShareableContent
    do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    catch { throw .permission }
    let filter: SCContentFilter
    let failure: VoiceScreenRefusal
    switch source {
    case .own: throw .failed
    case .window(let window):
      // A window missing from shareable content is one the system keeps private.
      guard let shareable = content.windows.first(where: { $0.windowID == window.id }) else { throw .protected(window.app) }
      filter = SCContentFilter(desktopIndependentWindow: shareable)
      failure = .protected(window.app)
    case .display(let id, let includesOwn, _):
      guard let display = content.displays.first(where: { $0.displayID == id }) else { throw .failed }
      let excluded = includesOwn ? [] : content.applications.filter { $0.processID == ownPID }
      filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
      failure = .failed
    }
    let configuration = SCStreamConfiguration()
    let scale = Double(filter.pointPixelScale)
    configuration.width = Int(filter.contentRect.width * scale)
    configuration.height = Int(filter.contentRect.height * scale)
    configuration.showsCursor = false
    do { return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
    catch let error as SCStreamError where error.code == .userDeclined { throw .permission }
    catch { throw failure }
  }
}
