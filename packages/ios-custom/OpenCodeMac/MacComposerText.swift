import AppKit
import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

// The composer's editor on the Mac: an `NSTextView` with the iPhone's atomic tokens (one attachment per token,
// one UTF-16 unit in TextKit, the full label on the wire) and the shared `ConversationDraft` as its model.
// Return sends and Shift+Return breaks the line, like Messages and the chat apps on the Mac; while the
// suggestion panel is open, Return picks its first item and Esc closes it.

/// A token drawn as its label on a tinted rounded background, in the token kind's theme color.
final class ComposerTokenAttachment: NSTextAttachment {
  let token: ComposerToken
  @MainActor init(_ token: ComposerToken, theme: AppTheme, font: NSFont) {
    self.token = token
    super.init(data: nil, ofType: nil)
    let color = theme.nsColor(token.kind.role)
    let label = NSAttributedString(string: token.text, attributes: [.font: font, .foregroundColor: color])
    let height = ceil(font.ascender - font.descender)
    let size = CGSize(width: ceil(label.size().width) + 8, height: height)
    image = NSImage(size: size, flipped: true) { rect in
      color.withAlphaComponent(0.12).setFill()
      NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
      label.draw(at: CGPoint(x: 4, y: 0))
      return true
    }
    bounds = CGRect(x: 0, y: font.descender, width: size.width, height: size.height)
  }
  required init?(coder: NSCoder) { nil }
}

extension ComposerDocument {
  @MainActor static var editorFont: NSFont { .systemFont(ofSize: AppTextStyle.message.size) }

  @MainActor func editorAttributed(theme: AppTheme = .selected, font: NSFont = ComposerDocument.editorFont)
    -> NSAttributedString
  {
    let result = NSMutableAttributedString(string: text, attributes: [
      .font: font, .foregroundColor: theme.nsColor(.text),
    ])
    for span in validTokens.reversed() {
      result.replaceCharacters(in: span.range, with: NSAttributedString(
        attachment: ComposerTokenAttachment(span.token, theme: theme, font: font)))
    }
    return result
  }

  @MainActor init(editor: NSAttributedString) {
    let source = editor.string as NSString
    let text = NSMutableString()
    var tokens: [ComposerSpan] = []
    editor.enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.length)) { value, range, _ in
      guard let attachment = value as? ComposerTokenAttachment else {
        text.append(source.substring(with: range))
        return
      }
      let start = text.length
      text.append(attachment.token.text)
      tokens.append(.init(start: start, end: text.length, token: attachment.token))
    }
    self.init(text: text as String, tokens: tokens)
  }
}

/// The editor as `ConversationDraft` sees it (the iPhone's `ComposerInputView` API): a scrolling container whose
/// text view holds the draft's editor text.
final class ComposerInputView: NSScrollView {
  let textView = ComposerTextNSView()
  weak var representedDraft: ConversationDraft?
  var composerOwner: UUID?
  var representedRevision = -1
  var composerTheme = AppTheme.selected
  var composerFont = ComposerDocument.editorFont
  /// The message role's reading line height (20 pt at 14 pt), the same as a prompt or an answer. Every line is
  /// exactly this tall, so the field's height is a whole number of lines and the first line is never clipped.
  let lineHeight = MacResponseTextStyle.lineHeight(.message)
  static let maximumLines: CGFloat = 8
  var plainAttributes: [NSAttributedString.Key: Any] {
    [.font: composerFont, .foregroundColor: composerTheme.nsColor(.text), .paragraphStyle: paragraph]
  }
  private var paragraph: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.minimumLineHeight = lineHeight
    style.maximumLineHeight = lineHeight
    return style
  }
  var textStorage: NSTextStorage { textView.textStorage! }
  var selectedRange: NSRange { textView.selectedRange() }
  /// Text being composed by an input method (accents, Japanese…), which Return must not send.
  var markedTextRange: NSRange? { textView.hasMarkedText() ? textView.markedRange() : nil }

  override init(frame: NSRect) {
    super.init(frame: frame)
    drawsBackground = false
    hasVerticalScroller = true
    autohidesScrollers = true
    borderType = .noBorder
    // At the window's bottom no bar overlaps it: an automatic inset would shift the text under the field's top.
    automaticallyAdjustsContentInsets = false
    contentInsets = NSEdgeInsetsZero
    verticalScroller = MacThinScroller()
    textView.input = self
    textView.isRichText = true
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.setAccessibilityLabel("Mensagem")
    textView.setAccessibilityIdentifier("conversation-composer")
    documentView = textView
  }
  required init?(coder: NSCoder) { nil }

  func restyle() {
    let selection = textView.selectedRange()
    textStorage.beginEditing()
    textStorage.addAttributes(plainAttributes, range: NSRange(location: 0, length: textStorage.length))
    textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
      guard let attachment = value as? ComposerTokenAttachment else { return }
      textStorage.addAttribute(.attachment,
        value: ComposerTokenAttachment(attachment.token, theme: composerTheme, font: composerFont), range: range)
    }
    textStorage.endEditing()
    textView.setSelectedRange(selection)
    textView.typingAttributes = plainAttributes
  }

  /// An undoable replacement (a token, a dictated text) that reports itself like typing.
  func replaceCharacters(in range: NSRange, with value: NSAttributedString) {
    let previous = textStorage.attributedSubstring(from: range)
    let selection = textView.selectedRange()
    textView.undoManager?.registerUndo(withTarget: self) { view in
      view.replaceCharacters(in: NSRange(location: range.location, length: value.length), with: previous)
      view.textView.setSelectedRange(selection)
    }
    textStorage.replaceCharacters(in: range, with: value)
    textView.setSelectedRange(NSRange(location: range.location + value.length, length: 0))
    textView.typingAttributes = plainAttributes
    textView.didChangeText()
  }

  /// The height the text needs at this width, one line at least. SwiftUI asks for several widths while it lays the
  /// composer out; only the field's own width is measured on its container. Resizing that container to another
  /// width left the text wrapped narrower than the field, taller than measured and scrolled: the top line was cut.
  func contentHeight(width: CGFloat) -> CGFloat { textView.textHeight(width: width, lineHeight: lineHeight) }

  /// Growing by a line, the text view scrolls its new last line into view before SwiftUI makes the field taller;
  /// once it is tall enough for everything, nothing may stay scrolled (that hid the top of the first line).
  override func tile() {
    super.tile()
    guard let document = documentView, document.frame.height <= contentView.bounds.height + 0.5,
      contentView.bounds.origin.y != 0 else { return }
    contentView.scroll(to: .zero)
    reflectScrolledClipView(contentView)
  }
}

extension NSTextView {
  /// The height of this text (TextKit 1, fixed `lineHeight` lines) at `width`, one line at least. The view's own
  /// container answers for its own width; any other width SwiftUI asks about is laid out on a copy, so the
  /// field's wrapping never changes under it.
  func textHeight(width: CGFloat, lineHeight: CGFloat) -> CGFloat {
    guard let manager = layoutManager, let container = textContainer, let textStorage else { return lineHeight }
    if abs(container.size.width - width) < 0.5 {
      manager.ensureLayout(for: container)
      return max(lineHeight, ceil(manager.usedRect(for: container).height))
    }
    let storage = NSTextStorage(attributedString: textStorage)
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let scratch = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    scratch.lineFragmentPadding = container.lineFragmentPadding
    layout.addTextContainer(scratch)
    layout.ensureLayout(for: scratch)
    // A trailing line break adds an empty last line, which the copy lays out in a default font.
    let extra = layout.extraLineFragmentRect.height
    return max(lineHeight, ceil(layout.usedRect(for: scratch).height + (extra > 0 ? lineHeight - extra : 0)))
  }
}

/// Return, Shift+Return, Esc, the suggestion panel's arrows, and pasting images or composer tokens.
final class ComposerTextNSView: NSTextView {
  weak var input: ComposerInputView?
  var submit: (() -> Void)?
  var dictate: (() -> Void)?
  var canSubmit = false
  var querying = false
  var firstSuggestion: (() -> (() -> Void)?)?
  var escape: (() -> Void)?
  var cancel: (() -> Void)?
  /// Image or file data pasted or dropped on the editor: the composer turns it into an attachment.
  var attach: (([NSPasteboardItem]) -> Bool)?
  var focusChanged: ((Bool) -> Void)?
  /// Drawn on the empty first line with the text's own font, color role and line height, so it sits exactly where
  /// typing starts.
  var placeholder = "" { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !placeholder.isEmpty, string.isEmpty, !hasMarkedText(), let input else { return }
    var attributes = input.plainAttributes
    attributes[.foregroundColor] = input.composerTheme.nsColor(.textSecondary)
    NSAttributedString(string: placeholder, attributes: attributes).draw(
      with: CGRect(origin: textContainerOrigin, size: CGSize(width: bounds.width, height: input.lineHeight)),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  override func didChangeText() {
    super.didChangeText()
    // The placeholder appears and leaves with the first character, outside the range TextKit redraws.
    if (textStorage?.length ?? 0) <= 1 { needsDisplay = true }
  }

  convenience init() {
    // TextKit 1: composer drafts are short, and its attachment layout is what the token images were drawn for.
    let storage = NSTextStorage()
    let manager = NSLayoutManager()
    storage.addLayoutManager(manager)
    let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
    manager.addTextContainer(container)
    self.init(frame: .zero, textContainer: container)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
      if !event.isARepeat { dictate?() }
      return
    }
    let key = event.charactersIgnoringModifiers
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if key == "\r" || key == "\u{3}" {
      if hasMarkedText() { return super.keyDown(with: event) }
      if flags.contains(.shift) || flags.contains(.option) {
        insertNewlineIgnoringFieldEditor(nil)
        return
      }
      let pick = firstSuggestion?()
      if ComposerReturn.selectsSuggestion(markedText: false, suggestionsOpen: querying, firstItemReady: pick != nil),
        let pick
      {
        pick()
        return
      }
      if querying { return }
      if canSubmit, let submit { submit() }
      return
    }
    if event.keyCode == 53, querying {
      escape?()
      return
    }
    // Inside a sheet (a quote's comment), Esc closes it instead of NSTextView's word completion.
    if event.keyCode == 53, let cancel {
      cancel()
      return
    }
    super.keyDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became { focusChanged?(true) }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { focusChanged?(false) }
    return resigned
  }

  private static let pasteboardType = NSPasteboard.PasteboardType("br.com.alexandrem.opencode.composer")

  override func copy(_ sender: Any?) {
    guard selectedRange().length > 0, let storage = textStorage else { return }
    let document = ComposerDocument(editor: storage.attributedSubstring(from: selectedRange()))
    let board = NSPasteboard.general
    board.clearContents()
    board.declareTypes([.string, Self.pasteboardType], owner: nil)
    board.setString(document.text, forType: .string)
    if let data = try? JSONEncoder().encode(document) { board.setData(data, forType: Self.pasteboardType) }
  }

  override func cut(_ sender: Any?) {
    guard isEditable, selectedRange().length > 0 else { return }
    copy(sender)
    input?.replaceCharacters(in: selectedRange(), with: NSAttributedString())
  }

  override func paste(_ sender: Any?) {
    guard isEditable else { return }
    let board = NSPasteboard.general
    if let data = board.data(forType: Self.pasteboardType),
      let document = try? JSONDecoder().decode(ComposerDocument.self, from: data), let input
    {
      input.replaceCharacters(in: selectedRange(),
        with: document.editorAttributed(theme: input.composerTheme, font: input.composerFont))
      return
    }
    // Images and files become attachments; external rich text arrives as plain text.
    if let items = board.pasteboardItems, items.contains(where: Self.attachable), attach?(items) == true { return }
    if let text = board.string(forType: .string) { insertText(text, replacementRange: selectedRange()) }
  }

  static func attachable(_ item: NSPasteboardItem) -> Bool {
    item.types.contains(.fileURL) || item.types.contains(.png) || item.types.contains(.tiff)
      || item.types.contains(NSPasteboard.PasteboardType(UTType.jpeg.identifier))
  }
}
