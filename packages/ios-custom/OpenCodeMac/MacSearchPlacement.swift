import AppKit
import SwiftUI

/// Geometry markers, not toolbar content: centering uses the whole detail, independently of the title's width.
struct MacSearchAnchor: NSViewRepresentable {
  enum Role { case title, actions }
  let role: Role
  func makeNSView(context: Context) -> Marker { Marker(role: role) }
  func updateNSView(_ view: Marker, context: Context) { view.schedule() }

  final class Marker: NSView {
    let role: Role
    init(role: Role) { self.role = role; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); schedule() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    func schedule() {
      guard let window else { return }
      NotificationCenter.default.post(name: .macSearchGeometry, object: window)
    }
  }
}

extension Notification.Name {
  static let macSearchGeometry = Notification.Name("OpenCodeMacSearchGeometry")
}

/// Mounted behind chat + Contexto. The field lives in the unified title bar, outside its glass item wrappers.
final class MacSearchPlacement: NSView {
  let field = MacSearchField()
  var reposition: (() -> Void)?
  private var scheduled = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.drawsBackground = true
    field.placeholderString = "Buscar projetos e sessões"
    field.setAccessibilityLabel("Buscar projetos e sessões")
    field.setAccessibilityIdentifier("mac-window-search")
    field.toolTip = "Buscar projetos e sessões (⌘K)"
    field.sendsSearchStringImmediately = true
    field.controlSize = .regular
    field.font = .systemFont(ofSize: 13)
    field.focusRingType = .none
  }
  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() { super.layout(); schedule() }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    field.removeFromSuperview()
    NotificationCenter.default.removeObserver(self)
    guard let window, let root = window.contentView?.superview else { return }
    root.addSubview(field, positioned: .above, relativeTo: nil)
    for name in [NSWindow.didResizeNotification, .macSearchGeometry] {
      NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(changed),
      name: NSSplitView.didResizeSubviewsNotification, object: nil)
    schedule()
  }

  @objc private func changed(_ notification: Notification) {
    if let split = notification.object as? NSSplitView, split.window !== window { return }
    schedule()
  }

  func schedule() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.scheduled = false
      self.place()
    }
  }

  /// Exposed to the hosted geometry checks, in the same coordinate space as the field.
  var geometry: (detail: NSRect, title: NSRect, actions: NSRect)? {
    guard let root = field.superview else { return nil }
    func markers(_ view: NSView) -> [MacSearchAnchor.Marker] {
      if let marker = view as? MacSearchAnchor.Marker { return [marker] }
      return view.subviews.flatMap(markers)
    }
    let anchors = markers(root)
    guard let title = anchors.first(where: { $0.role == .title }),
      let actions = anchors.first(where: { $0.role == .actions }) else { return nil }
    return (convert(bounds, to: root), title.convert(title.bounds, to: root), actions.convert(actions.bounds, to: root))
  }

  private func place() {
    guard let geometry, geometry.detail.width > 0 else { return }
    let center = geometry.detail.midX
    let half = max(0, min(260, center - geometry.title.maxX - 12, geometry.actions.minX - 12 - center))
    field.frame = NSRect(x: center - half, y: geometry.actions.midY - 14, width: half * 2, height: 28)
    reposition?()
  }

  func stop() {
    reposition = nil
    field.removeFromSuperview()
    NotificationCenter.default.removeObserver(self)
  }
}

/// The cell comes from `cellClass`, so NSTextField configures it as editable and selectable. A cell assigned
/// afterwards (`field.cell = …`) starts as plain static text: the field then refuses first responder, clicks do
/// nothing and ⌘K cannot focus it.
final class MacSearchField: NSSearchField {
  /// A click or ⌘K focusing the field opens the list.
  var focused: (() -> Void)?
  override class var cellClass: AnyClass? {
    get { MacSearchCell.self }
    set {}
  }
  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { focused?() }
    return became
  }
}

/// Keeps native search/clear/editing behavior, reserving a small trailing area for the persistent shortcut hint.
private final class MacSearchCell: NSSearchFieldCell {
  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    var text = super.searchTextRect(forBounds: rect)
    text.size.width = max(0, text.width - 32)
    return text
  }
  override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
    super.cancelButtonRect(forBounds: rect).offsetBy(dx: -32, dy: 0)
  }
  override func draw(withFrame rect: NSRect, in view: NSView) {
    super.draw(withFrame: rect, in: view)
    let hint = NSAttributedString(string: "⌘K", attributes: [
      .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
    ])
    hint.draw(at: NSPoint(x: rect.maxX - 29, y: rect.midY - hint.size().height / 2))
  }
}
