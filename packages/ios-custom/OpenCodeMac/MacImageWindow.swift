import AppKit
import SwiftUI

/// An image from the conversation in its own resizable window rather than a sheet (a sheet cannot be resized by the
/// user nor grow past its window). It opens at the image's size (one image pixel per screen pixel), at most 90% of
/// the visible screen, fitted to the window; zoom and pan work like Preview (`MacImageScrollView`). ⌘C (or the
/// right-click menu) copies it, the title bar's icon or ⌥ + drag drags it out as a PNG file, and Esc or a click
/// outside (the window stops being key) closes it, like the modals, once a pan, a drag out or the menu is over.
@MainActor final class MacImageWindow: NSObject, NSWindowDelegate {
  private static var open: Set<MacImageWindow> = []
  private let window: NSWindow
  private let parent: NSWindow?
  private let zoom: MacImageZoom
  private var resized = false
  private var leaving = false

  static func show(_ image: MacViewedImage, theme: AppTheme, over parent: NSWindow?) {
    let viewer = MacImageWindow(image: image, theme: theme, parent: parent)
    open.insert(viewer)
    viewer.window.makeKeyAndOrderFront(nil)
    viewer.zoom.canvas?.focus()
  }

  private init(image: MacViewedImage, theme: AppTheme, parent: NSWindow?) {
    window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    self.parent = parent
    zoom = MacImageZoom(image: image.image, name: image.name)
    super.init()
    window.title = image.name
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
    window.backgroundColor = theme.nsColor(.background)
    window.contentMinSize = NSSize(width: 560, height: 260)
    window.delegate = self
    zoom.close = { [weak window] in window?.close() }
    zoom.settled = { [weak self] in self?.closeIfLeft() }
    zoom.exported = { [weak window] file in window?.representedURL = file }
    let host = NSHostingController(rootView: MacImageViewer(image: image, zoom: zoom) { [weak self] original in
      guard let self, !self.resized else { return }
      self.place(original)
    }
    .environment(\.appTheme, theme).environment(\.locale, Locale(identifier: "pt_BR")))
    host.sizingOptions = []
    window.contentViewController = host
    place(image.image)
    zoom.export()
  }

  func windowDidEndLiveResize(_ notification: Notification) { resized = true }
  func windowDidBecomeKey(_ notification: Notification) { leaving = false }
  func windowDidResignKey(_ notification: Notification) {
    leaving = true
    closeIfLeft()
  }
  func windowWillClose(_ notification: Notification) { Self.open.remove(self) }

  /// The title bar's icon drags the PNG out as a copy (it is a temporary file, which a move would take away).
  func window(_ window: NSWindow, shouldDragDocumentWith event: NSEvent, from dragImageLocation: NSPoint,
    with pasteboard: NSPasteboard) -> Bool
  {
    if let icon = window.standardWindowButton(.documentIconButton) { zoom.canvas?.dragOut(from: icon, event: event) }
    return false
  }

  /// Its path would only show the temporary folder.
  func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool { false }

  /// A click outside closes the window, but never in the middle of a pan, a drag out or with the menu open.
  private func closeIfLeft() {
    if leaving, !zoom.busy, !window.isKeyWindow { window.close() }
  }

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

/// The viewer's state shared by its bar (SwiftUI) and its canvas (AppKit).
@MainActor @Observable final class MacImageZoom {
  private(set) var image: CGImage
  let name: String
  /// The magnification in whole percents: 100% is one image pixel per screen pixel.
  var percent = 100
  var fits = true
  var actual = false
  var canZoomIn = true
  var canZoomOut = false
  @ObservationIgnored weak var canvas: MacImageScrollView?
  @ObservationIgnored var close: () -> Void = {}
  /// A pan, a drag out or the menu is going on; `settled` runs when it ends.
  @ObservationIgnored var busy = false {
    didSet { if oldValue, !busy { settled() } }
  }
  @ObservationIgnored var settled: () -> Void = {}
  /// The PNG written for dragging out, also the window's represented file (its title bar icon).
  @ObservationIgnored private(set) var file: URL?
  @ObservationIgnored var exported: (URL) -> Void = { _ in }

  init(image: CGImage, name: String) {
    self.image = image
    self.name = name
  }

  /// The original file, once read: the canvas keeps the zoom on screen.
  func show(_ original: CGImage) {
    image = original
    file = nil
    canvas?.show(original)
    export()
  }

  /// Writes the PNG in the background (a 4000-px board takes a moment).
  func export() {
    let image = image
    let name = name
    Task { [weak self] in
      let file = await Task.detached(priority: .utility) { MacImageTransfer.file(image, name: name) }.value
      guard let self, let file, image === self.image else { return }
      self.file = file
      exported(file)
    }
  }

  /// The PNG to drag right now: the one written in the background, or a new one.
  func fileNow() -> URL? {
    if file == nil, let written = MacImageTransfer.file(image, name: name) {
      file = written
      exported(written)
    }
    return file
  }
}

private struct MacImageViewer: View {
  /// The bar and its hairline.
  static let header: CGFloat = 45
  @Environment(\.appTheme) private var theme
  let image: MacViewedImage
  let zoom: MacImageZoom
  let loaded: (CGImage) -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        MacImageZoomBar(zoom: zoom)
        Spacer(minLength: 12)
        Button("Copiar imagem", systemImage: "doc.on.doc") { MacImageTransfer.copy(zoom.image) }
          .shortcut(.copyImage)
          .help("Copiar imagem (⌘C)")
        Button("Fechar") { zoom.close() }.keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 12).frame(height: Self.header - 1)
      ContextHairline()
      MacImageCanvas(zoom: zoom, background: theme.nsColor(.background))
        .accessibilityLabel(image.name)
    }
    .background(theme.color(.background))
    .task {
      guard let value = await image.original?() else { return }
      let grew = value.width != zoom.image.width || value.height != zoom.image.height
      zoom.show(value)
      if grew { loaded(value) }
    }
  }
}

/// − 42% + | Ajustar · Tamanho real, borderless like the title bar's icons. The percentage fits the window too.
private struct MacImageZoomBar: View {
  @Environment(\.appTheme) private var theme
  let zoom: MacImageZoom

  var body: some View {
    HStack(spacing: 2) {
      Button { zoom.canvas?.step(-1) } label: { MacToolbarIcon(symbol: "minus") }
        .disabled(!zoom.canZoomOut).help("Reduzir (⌘−)").accessibilityLabel("Reduzir")
      Button { zoom.canvas?.fitToWindow() } label: { MacImageBarLabel(text: "\(zoom.percent)%", minWidth: 52) }
        .help("Ajustar à janela (⌘0)").accessibilityLabel(Text(verbatim: "Zoom de \(zoom.percent)%; ajustar à janela"))
      Button { zoom.canvas?.step(1) } label: { MacToolbarIcon(symbol: "plus") }
        .disabled(!zoom.canZoomIn).help("Ampliar (⌘+)").accessibilityLabel("Ampliar")
      Rectangle().fill(theme.color(.border)).frame(width: 1, height: 16).padding(.horizontal, 6)
      Button { zoom.canvas?.fitToWindow() } label: { MacImageBarLabel(text: "Ajustar", selected: zoom.fits) }
        .help("Ajustar à janela (⌘0)")
      Button { zoom.canvas?.actualSize() } label: { MacImageBarLabel(text: "Tamanho real", selected: zoom.actual) }
        .help("Tamanho real: um pixel da imagem por pixel da tela (⌘1)")
    }
    .buttonStyle(.plain)
  }
}

private struct MacImageBarLabel: View {
  @Environment(\.appTheme) private var theme
  let text: String
  var selected = false
  var minWidth: CGFloat?
  @State private var hovering = false

  var body: some View {
    Text(verbatim: text).font(.system(size: 12, weight: selected ? .semibold : .regular)).monospacedDigit()
      .foregroundStyle(theme.color(selected ? .textStrong : .textSecondary))
      .padding(.horizontal, 8).frame(minWidth: minWidth, minHeight: 26)
      .background(theme.color(.highlight).opacity(selected ? 1 : hovering ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

private struct MacImageCanvas: NSViewRepresentable {
  let zoom: MacImageZoom
  let background: NSColor
  func makeNSView(context: Context) -> MacImageScrollView { MacImageScrollView(zoom: zoom, background: background) }
  func updateNSView(_ view: MacImageScrollView, context: Context) {}
}

/// The image at full resolution in one layer, magnified by the scroll view, so zooming and panning a 4000-px board
/// stays on the GPU. 100% is one image pixel per screen pixel; from 10% (or the fit, if smaller) to 1600%.
/// A mouse's wheel and ⌘ + scroll zoom around the pointer; the trackpad's and Magic Mouse's scroll pans with
/// inertia and their pinch zooms; dragging pans (⌥ + drag drags the file out); a double click or a two-finger
/// double tap switches between fitting the window and 100%; ⌘+ ⌘= ⌘− ⌘0 ⌘1, the arrows and Esc.
final class MacImageScrollView: NSScrollView, NSMenuDelegate, NSDraggingSource {
  private static let levels: [CGFloat] = [0.1, 0.125, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16]
  private let model: MacImageZoom
  private let canvas = MacImageLayerView()
  /// Fitting the window: a resize fits it again.
  private var fitting = true
  /// The last pointer position of a pan, in the window.
  private var grab: NSPoint?
  /// ⌥ was down at the click: the drag takes the file out.
  private var outward = false
  private var menuOpen = false
  private var draggingOut = false
  /// A smooth zoom: the image point kept under `location` (in this view) while the magnification reaches `target`.
  private var animation: (target: CGFloat, anchor: NSPoint, location: NSPoint)?
  private var link: CADisplayLink?
  /// Where the arrows' scroll is heading, so a key pressed during it adds to it.
  private var scrolling: NSPoint?

  init(zoom: MacImageZoom, background: NSColor) {
    model = zoom
    super.init(frame: .zero)
    contentView = MacImageClipView()
    documentView = canvas
    hasVerticalScroller = true
    hasHorizontalScroller = true
    autohidesScrollers = true
    adoptThinScrollers()
    usesPredominantAxisScrolling = false
    allowsMagnification = true
    maxMagnification = Self.levels[Self.levels.count - 1]
    backgroundColor = background
    canvas.image = zoom.image
    zoom.canvas = self
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: Zoom

  func fitToWindow() {
    fitting = true
    zoom(to: fitMagnification)
  }

  func actualSize() {
    fitting = false
    zoom(to: 1)
  }

  /// ⌘+ and ⌘−: the next step of a Preview-like scale that passes through the fit.
  func step(_ direction: Int) {
    let current = animation?.target ?? magnification
    let fit = fitMagnification
    let levels = (Self.levels + [fit]).sorted()
    guard let next = direction > 0 ? levels.first(where: { $0 > current * 1.01 })
      : levels.last(where: { $0 < current * 0.99 }) else { return }
    fitting = next == fit
    zoom(to: next)
  }

  /// Fit ↔ 100% (200% when the image already fits at 100%), keeping the point under `location` in place.
  func toggle(at location: NSPoint) {
    let fit = fitMagnification
    guard fitting || abs(magnification - fit) < 0.005 else { return fitToWindow() }
    fitting = false
    zoom(to: fit > 0.995 ? 2 : 1, at: location)
  }

  /// The original file replaced the chat's copy: the same part of the image stays on screen at the same size.
  func show(_ image: CGImage) {
    canvas.image = image
    resizeDocument()
  }

  /// Zooms to `value` keeping the image point under `location` (the middle by default) in place, smoothly
  /// unless `animated` is false, the window is off the screens or Reduce Motion is on.
  private func zoom(to value: CGFloat, at location: NSPoint? = nil, animated: Bool = true) {
    let value = min(max(value, minMagnification), maxMagnification)
    let location = location ?? middle
    let anchor = contentView.convert(location, from: self)
    guard animated, window?.screen != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      stopAnimation()
      apply(value, anchor: anchor, at: location)
      return
    }
    animation = (value, anchor, location)
    guard link == nil else { return }
    link = displayLink(target: self, selector: #selector(advance(_:)))
    link?.add(to: .main, forMode: .common)
  }

  /// One frame of the smooth zoom: an exponential approach in log scale, about a quarter of a second.
  @objc private func advance(_ link: CADisplayLink) {
    guard let animation else { return stopAnimation() }
    let current = log(magnification)
    let target = log(animation.target)
    let next = abs(target - current) < 0.004 ? target
      : current + (target - current) * (1 - exp(-(link.targetTimestamp - link.timestamp) / 0.055))
    apply(exp(next), anchor: animation.anchor, at: animation.location)
    if next == target { stopAnimation() }
  }

  private func stopAnimation() {
    link?.invalidate()
    link = nil
    animation = nil
  }

  /// Sets the magnification with the image point `anchor` under `location` (in this view); an image smaller than
  /// the window stays in its middle (`MacImageClipView`).
  private func apply(_ value: CGFloat, anchor: NSPoint, at location: NSPoint) {
    let clip = contentView
    magnification = value
    let under = clip.convert(location, from: self)
    let origin = NSPoint(x: clip.bounds.minX + anchor.x - under.x, y: clip.bounds.minY + anchor.y - under.y)
    clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
    reflectScrolledClipView(clip)
  }

  /// The middle of what shows the image (scroll bars that are always shown take some room).
  private var middle: NSPoint { NSPoint(x: contentView.frame.midX, y: contentView.frame.midY) }

  /// The whole image in the window, never above 100%. At that size no scroll bar shows.
  private var fitMagnification: CGFloat {
    let size = canvas.frame.size
    let room = bounds.size
    guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return 1 }
    return min(1, room.width / size.width, room.height / size.height)
  }

  /// The image at 100% on this window's screen, keeping its size on screen (or the fit) and its middle.
  private func resizeDocument() {
    guard let image = canvas.image else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let old = canvas.frame.size
    guard size != old else { return }
    let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    let shown = magnification
    stopAnimation()
    canvas.frame = NSRect(origin: .zero, size: size)
    minMagnification = min(fitMagnification, Self.levels[0])
    guard !fitting, old.width > 0 else { return apply(fitMagnification, anchor: center, at: middle) }
    let ratio = size.width / old.width
    apply(shown / ratio, anchor: NSPoint(x: center.x * ratio, y: center.y * ratio), at: middle)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return stopAnimation() }
    resizeDocument()
    Task { [weak self] in
      self?.focus()
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    resizeDocument()
  }

  /// Fitting follows the window; a manual zoom keeps the point in the middle.
  override func setFrameSize(_ newSize: NSSize) {
    let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    guard changed, canvas.frame.width > 0, newSize.width > 0, newSize.height > 0 else { return }
    minMagnification = min(fitMagnification, Self.levels[0])
    if fitting { stopAnimation() }
    apply(fitting ? fitMagnification : min(max(magnification, minMagnification), maxMagnification), anchor: center,
      at: middle)
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    publish()
  }

  /// The bar's percentage and states, the pixels' filter and the hand cursor.
  private func publish() {
    let percent = Int((magnification * 100).rounded())
    if model.percent != percent { model.percent = percent }
    if model.fits != fitting { model.fits = fitting }
    let actual = abs(magnification - 1) < 0.001
    if model.actual != actual { model.actual = actual }
    let zoomIn = magnification < maxMagnification - 0.001
    if model.canZoomIn != zoomIn { model.canZoomIn = zoomIn }
    let zoomOut = magnification > minMagnification + 0.001
    if model.canZoomOut != zoomOut { model.canZoomOut = zoomOut }
    canvas.sharp = magnification >= 2
    let cursor: NSCursor? = pannable ? .openHand : nil
    if documentCursor != cursor { documentCursor = cursor }
  }

  /// Larger than the window: dragging moves it.
  private var pannable: Bool {
    contentView.bounds.width < canvas.frame.width - 0.5 || contentView.bounds.height < canvas.frame.height - 0.5
  }

  // MARK: Wheel, trackpad and mouse

  override func scrollWheel(with event: NSEvent) {
    // A mouse's wheel has no phases; the trackpad and the Magic Mouse have them and pan, unless ⌘ is down.
    let wheel = event.phase.isEmpty && event.momentumPhase.isEmpty
    guard wheel || event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else {
      stopAnimation()
      return super.scrollWheel(with: event)
    }
    // Away from you zooms in, whatever the scrolling direction setting.
    let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
    let factor = event.hasPreciseScrollingDeltas ? exp(delta * 0.01) : pow(1.2, min(max(delta, -4), 4))
    fitting = false
    zoom(to: (animation?.target ?? magnification) * factor, at: convert(event.locationInWindow, from: nil),
      animated: !event.hasPreciseScrollingDeltas)
  }

  override func magnify(with event: NSEvent) {
    stopAnimation()
    fitting = false
    super.magnify(with: event)
  }

  override func smartMagnify(with event: NSEvent) {
    toggle(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseDown(with event: NSEvent) {
    focus()
    stopAnimation()
    if event.clickCount == 2 { return toggle(at: convert(event.locationInWindow, from: nil)) }
    if event.modifierFlags.contains(.option) {
      outward = true
      return
    }
    guard pannable else { return }
    grab = event.locationInWindow
    NSCursor.closedHand.push()
    model.busy = true
  }

  override func mouseDragged(with event: NSEvent) {
    if outward {
      outward = false
      return dragOut(from: self, event: event)
    }
    guard let last = grab else { return }
    grab = event.locationInWindow
    let clip = contentView
    let origin = NSPoint(x: clip.bounds.minX - (event.locationInWindow.x - last.x) / magnification,
      y: clip.bounds.minY + (event.locationInWindow.y - last.y) / magnification)
    clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
    reflectScrolledClipView(clip)
  }

  override func mouseUp(with event: NSEvent) {
    outward = false
    guard grab != nil else { return }
    grab = nil
    NSCursor.pop()
    settle()
  }

  // MARK: Keys

  /// The keys (arrows, Esc) go to the image rather than the bar's buttons. The image takes the focus (a scroll view
  /// does not keep it) and passes its keys up here.
  func focus() {
    window?.makeFirstResponder(canvas)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control]) == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers {
    case "+", "=": step(1)
    case "-": step(-1)
    case "0": fitToWindow()
    case "1": actualSize()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  override func keyDown(with event: NSEvent) {
    let page = event.modifierFlags.contains(.option)
    switch event.keyCode {
    case 123: pan(x: -1, y: 0, page: page)
    case 124: pan(x: 1, y: 0, page: page)
    case 125: pan(x: 0, y: 1, page: page)
    case 126: pan(x: 0, y: -1, page: page)
    case 53: model.close()
    default: super.keyDown(with: event)
    }
  }

  /// The arrows move 60 pt; with ⌥, most of the window.
  private func pan(x: CGFloat, y: CGFloat, page: Bool) {
    stopAnimation()
    let clip = contentView
    let base = scrolling ?? clip.bounds.origin
    let step = page ? clip.bounds.size : NSSize(width: 60 / magnification, height: 60 / magnification)
    let origin = NSPoint(x: base.x + x * step.width * (page ? 0.85 : 1), y: base.y + y * step.height * (page ? 0.85 : 1))
    let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
    guard window?.screen != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      clip.setBoundsOrigin(target)
      return reflectScrolledClipView(clip)
    }
    scrolling = target
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      clip.animator().setBoundsOrigin(target)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated { if self?.scrolling == target { self?.scrolling = nil } }
    }
  }

  // MARK: Menu, copy and dragging out

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(item("Copiar imagem", #selector(copy(_:)), "c"))
    menu.addItem(.separator())
    menu.addItem(item("Ampliar", #selector(zoomIn(_:)), "+"))
    menu.addItem(item("Reduzir", #selector(zoomOut(_:)), "-"))
    menu.addItem(item("Ajustar à janela", #selector(fitAction(_:)), "0", on: fitting))
    menu.addItem(item("Tamanho real", #selector(actualAction(_:)), "1", on: abs(magnification - 1) < 0.001))
    return menu
  }

  private func item(_ title: String, _ action: Selector, _ key: String, on: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    item.state = on ? .on : .off
    return item
  }

  @objc func copy(_ sender: Any?) { MacImageTransfer.copy(model.image) }
  @objc private func zoomIn(_ sender: Any?) { step(1) }
  @objc private func zoomOut(_ sender: Any?) { step(-1) }
  @objc private func fitAction(_ sender: Any?) { fitToWindow() }
  @objc private func actualAction(_ sender: Any?) { actualSize() }

  func menuWillOpen(_ menu: NSMenu) {
    menuOpen = true
    model.busy = true
  }

  func menuDidClose(_ menu: NSMenu) {
    menuOpen = false
    settle()
  }

  /// Drags the image out as its PNG file, from this view (⌥ + drag) or the title bar's icon.
  func dragOut(from view: NSView, event: NSEvent) {
    guard let file = model.fileNow() else { return }
    let image = model.image
    let scale = min(160 / CGFloat(image.width), 160 / CGFloat(image.height), 1)
    let size = NSSize(width: max(1, (CGFloat(image.width) * scale).rounded()),
      height: max(1, (CGFloat(image.height) * scale).rounded()))
    let point = view.convert(event.locationInWindow, from: nil)
    let item = NSDraggingItem(pasteboardWriter: file as NSURL)
    item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width,
      height: size.height), contents: NSImage(cgImage: image, size: size))
    draggingOut = true
    model.busy = true
    view.beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    .copy
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    draggingOut = false
    settle()
  }

  private func settle() {
    if grab == nil, !menuOpen, !draggingOut { model.busy = false }
  }
}

/// Keeps an image smaller than the window in its middle; clicks on the margins pan and open the menu too.
private final class MacImageClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let document = documentView?.frame else { return rect }
    if rect.width > document.width { rect.origin.x = ((document.width - rect.width) / 2).rounded() }
    if rect.height > document.height { rect.origin.y = ((document.height - rect.height) / 2).rounded() }
    return rect
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
  override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }
  override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
  override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }
}

/// The image as a layer's contents: mipmapped when reduced, hard pixels from 200% up.
private final class MacImageLayerView: NSView {
  var image: CGImage? { didSet { needsDisplay = true } }
  var sharp = false { didSet { if sharp != oldValue { needsDisplay = true } } }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func updateLayer() {
    guard let layer else { return }
    layer.contents = image
    layer.contentsGravity = .resize
    layer.minificationFilter = .trilinear
    layer.magnificationFilter = sharp ? .nearest : .linear
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { enclosingScrollView?.mouseDown(with: event) }
  override func mouseDragged(with event: NSEvent) { enclosingScrollView?.mouseDragged(with: event) }
  override func mouseUp(with event: NSEvent) { enclosingScrollView?.mouseUp(with: event) }
  override func menu(for event: NSEvent) -> NSMenu? { enclosingScrollView?.menu(for: event) }
}
