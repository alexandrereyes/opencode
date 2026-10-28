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
  var plainAttributes: [NSAttributedString.Key: Any] {
    [.font: composerFont, .foregroundColor: composerTheme.nsColor(.text)]
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

  /// The height the text needs at this width, one line at least.
  func contentHeight(width: CGFloat) -> CGFloat {
    let line = ceil(composerFont.ascender - composerFont.descender + composerFont.leading)
    guard let manager = textView.layoutManager, let container = textView.textContainer else { return line }
    if container.size.width != width { container.size = CGSize(width: width, height: .greatestFiniteMagnitude) }
    manager.ensureLayout(for: container)
    return max(line, ceil(manager.usedRect(for: container).height))
  }
}

/// Return, Shift+Return, Esc, the suggestion panel's arrows, and pasting images or composer tokens.
final class ComposerTextNSView: NSTextView {
  weak var input: ComposerInputView?
  var submit: (() -> Void)?
  var canSubmit = false
  var querying = false
  var firstSuggestion: (() -> (() -> Void)?)?
  var escape: (() -> Void)?
  /// Image or file data pasted or dropped on the editor: the composer turns it into an attachment.
  var attach: (([NSPasteboardItem]) -> Bool)?
  var focusChanged: ((Bool) -> Void)?

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
