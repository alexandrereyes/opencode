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
  /// The height last given to SwiftUI for the field's own width (`MacComposerEditor.sizeThatFits`).
  var measuredHeight: CGFloat?
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
    // Created in code, the text view's size limits default to its zero frame: past the field's height the text would
    // be clipped instead of growing taller than the clip view and scrolling.
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    textView.disableAutomaticCorrections()
    textView.setAccessibilityLabel("Mensagem")
    textView.setAccessibilityIdentifier("conversation-composer")
    documentView = textView
    NotificationCenter.default.addObserver(self, selector: #selector(textEdited),
      name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
  }
  required init?(coder: NSCoder) { nil }

  /// Heights of the text at the widths SwiftUI asked about, until the text or its attributes change.
  private var heights: [CGFloat: CGFloat] = [:]
  @objc private func textEdited() { heights.removeAll() }

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
  /// A window's layout pass asks the same widths again and again; other widths are laid out on a copy of the text,
  /// so their heights are kept until the text changes.
  func contentHeight(width: CGFloat) -> CGFloat {
    if let height = heights[width] { return height }
    let height = textView.textHeight(width: width, lineHeight: lineHeight)
    if heights.count > 16 { heights.removeAll() }
    heights[width] = height
    return height
  }

  /// Growing by a line, the text view scrolls its new last line into view before SwiftUI makes the field taller;
  /// once it is tall enough for everything, nothing may stay scrolled (that hid the top of the first line).
  override func tile() {
    super.tile()
    guard let document = documentView else { return }
    // The clip view is flipped and the text view only tracks its width: autoresizing moved the text view by the
    // field's change in height. Shrinking back to one line (an empty draft, after sending) left its frame at y -14,
    // the placeholder and caret cut in half above the field.
    if document.frame.origin != .zero { document.setFrameOrigin(.zero) }
    guard document.frame.height <= contentView.bounds.height + 0.5,
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
extension NSTextView {
  /// Mac composers keep what is typed: no autocorrection, capitalization, text replacement, smart quotes or dashes,
  /// and no inline predictions. Misspellings are only underlined. (The iPhone keeps the system's corrections.)
  func disableAutomaticCorrections() {
    enabledTextCheckingTypes = NSTextCheckingResult.CheckingType.spelling.rawValue
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticTextCompletionEnabled = false
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticDataDetectionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isGrammarCheckingEnabled = false
    inlinePredictionType = .no
  }
}

final class ComposerTextNSView: NSTextView {
  weak var input: ComposerInputView?
  var submit: (() -> Void)?
  var dictate: (() -> Void)?
  var canSubmit = false
  var querying = false
  var firstSuggestion: (() -> (() -> Void)?)?
  /// Moves the panel's highlight by ±1; false while it has nothing to move through.
  var moveSuggestion: ((Int) -> Bool)?
  /// ⌘N while the `#` panel is open: a new snippet instead of Nova sessão.
  var newSnippet: (() -> Void)?
  /// "Salvar como snippet…" in a selection's context menu, with the selected text (snippet tokens expanded).
  var saveSnippet: ((String) -> Void)?
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

  // Inside the transcript's hosted rows (a question's answer) the first click must focus the field.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    super.mouseDown(with: event)
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
    // While the panel is open, ↑/↓ (and ⌃P/⌃N, like the system's lists) move its highlight instead of the caret, and
    // Tab picks it like Return.
    if querying, !hasMarkedText() {
      let plain = flags.subtracting([.numericPad, .function, .capsLock]).isEmpty
      let control = flags.subtracting([.capsLock]) == .control
      let delta: Int? =
        if plain, event.keyCode == 125 || event.keyCode == 126 { event.keyCode == 125 ? 1 : -1 }
        else if control, key == "n" || key == "p" { key == "n" ? 1 : -1 }
        else { nil }
      if let delta {
        _ = moveSuggestion?(delta)
        return
      }
      if plain, event.keyCode == 48 {
        firstSuggestion?()?()
        return
      }
    }
    // Inside a sheet (a quote's comment), Esc closes it instead of NSTextView's word completion.
    if event.keyCode == 53, let cancel {
      cancel()
      return
    }
    super.keyDown(with: event)
  }

  // The window's views see key equivalents before the main menu, so ⌘N reaches the editor first.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let newSnippet, window?.firstResponder === self,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "n" {
      newSnippet()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event)
    guard let menu, saveSnippet != nil, selectedRange().length > 0 else { return menu }
    let item = NSMenuItem(title: "Salvar como snippet…", action: #selector(saveSelectionAsSnippet), keyEquivalent: "")
    item.target = self
    menu.insertItem(item, at: 0)
    menu.insertItem(.separator(), at: 1)
    return menu
  }

  /// The selection as the composer would send it: snippet tokens become their text, the others keep theirs.
  @objc func saveSelectionAsSnippet() {
    guard let saveSnippet, selectedRange().length > 0, let storage = textStorage else { return }
    let text = ComposerDocument(editor: storage.attributedSubstring(from: selectedRange())).expanded.text
    guard !text.allSatisfy(\.isWhitespace) else { return }
    saveSnippet(text)
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

  // Rich text without graphics cannot read an image-only pasteboard (a screenshot), so AppKit would disable Paste
  // (⌘V) before `paste(_:)` gets the chance to turn it into an attachment.
  private var pastesAttachment: Bool {
    isEditable && attach != nil && NSPasteboard.general.pasteboardItems?.contains(where: Self.attachable) == true
  }

  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(paste(_:)), pastesAttachment { return true }
    return super.validateMenuItem(menuItem)
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(paste(_:)), pastesAttachment { return true }
    return super.validateUserInterfaceItem(item)
  }

  static func attachable(_ item: NSPasteboardItem) -> Bool {
    item.types.contains(.fileURL) || item.types.contains(.png) || item.types.contains(.tiff)
      || item.types.contains(NSPasteboard.PasteboardType(UTType.jpeg.identifier))
  }
}
