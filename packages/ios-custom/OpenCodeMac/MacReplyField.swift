import AppKit
import SwiftUI

/// A question's own answer ("Outra resposta…") on the Mac: a native text view that a click focuses, where Return
/// sends (`submit`), Shift+Return or Option+Return break the line and Esc leaves the field. It grows to six lines,
/// then scrolls. A SwiftUI `TextField` ends editing on Return without sending, and inside the transcript's hosted
/// rows it did not reliably take the focus.
struct MacReplyField: NSViewRepresentable {
  @Environment(\.appTheme) private var theme
  @Binding var text: String
  let placeholder: String
  let submit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsetsZero
    scroll.verticalScroller = MacThinScroller()
    let view = MacReplyTextView()
    view.delegate = context.coordinator
    view.isRichText = false
    view.allowsUndo = true
    view.drawsBackground = false
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]
    view.disableAutomaticCorrections()
    view.setAccessibilityLabel(placeholder)
    view.setAccessibilityIdentifier("question-reply")
    scroll.documentView = view
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let view = scroll.documentView as? MacReplyTextView else { return }
    view.submit = submit
    view.placeholder = placeholder
    let font = NSFont.systemFont(ofSize: AppTextStyle.preview.size)
    view.font = font
    view.textColor = theme.nsColor(.text)
    view.insertionPointColor = theme.nsColor(.primary)
    view.placeholderColor = theme.nsColor(.textSecondary)
    view.typingAttributes = [.font: font, .foregroundColor: theme.nsColor(.text), .paragraphStyle: view.paragraph]
    if view.string != text, !view.hasMarkedText() {
      view.string = text
      view.textStorage?.addAttributes(view.typingAttributes, range: NSRange(location: 0, length: (text as NSString).length))
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width > 0, let view = nsView.documentView as? MacReplyTextView else { return nil }
    let line = MacReplyTextView.lineHeight
    return CGSize(width: width, height: min(view.textHeight(width: width, lineHeight: line), line * 6))
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: MacReplyField
    init(_ parent: MacReplyField) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSTextView else { return }
      if parent.text != view.string { parent.text = view.string }
      view.enclosingScrollView?.invalidateIntrinsicContentSize()
    }
  }
}

final class MacReplyTextView: NSTextView {
  static let lineHeight = ceil(AppTextStyle.preview.size * 1.35)
  var submit: (() -> Void)?
  var placeholder = "" { didSet { needsDisplay = true } }
  var placeholderColor = NSColor.secondaryLabelColor
  let paragraph: NSParagraphStyle = {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = MacReplyTextView.lineHeight
    style.maximumLineHeight = MacReplyTextView.lineHeight
    return style
  }()

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" {
      if hasMarkedText() { return super.keyDown(with: event) }
      if flags.contains(.shift) || flags.contains(.option) {
        insertNewlineIgnoringFieldEditor(nil)
      } else {
        submit?()
      }
      return
    }
    if event.keyCode == 53 {
      window?.makeFirstResponder(nil)
      return
    }
    super.keyDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText(), let font else { return }
    NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: placeholderColor,
      .paragraphStyle: paragraph]).draw(
      with: CGRect(origin: textContainerOrigin, size: CGSize(width: bounds.width, height: Self.lineHeight)),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  override func didChangeText() {
    super.didChangeText()
    if (textStorage?.length ?? 0) <= 1 { needsDisplay = true }
  }
}
