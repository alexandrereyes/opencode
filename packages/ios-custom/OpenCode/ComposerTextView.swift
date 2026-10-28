import OpenCodeKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerTextView: UIViewRepresentable {
  @Environment(\.dynamicTypeSize) private var typeSize
  @Bindable var draft: ConversationDraft
  let theme: AppTheme
  var expanded: Bool
  let owner: UUID
  var label = "Mensagem"
  var identifier = "conversation-composer"
  var submit: (() -> Void)? = nil
  var canSubmit = false
  /// Picks the open suggestion panel's first item, when it has loaded one for the current trigger.
  var firstSuggestion: (() -> (() -> Void)?)? = nil
  /// Imports pasted or dropped images as draft attachments; without it they are ignored.
  var importImages: (([NSItemProvider]) -> Void)? = nil
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> ComposerInputView {
    let view = ComposerInputView(frame: .zero, textContainer: nil)
    // Images are accepted for paste and drop only to leave the text as attachments, never as text glyphs.
    view.pasteConfiguration = UIPasteConfiguration(
      acceptableTypeIdentifiers: (view.pasteConfiguration?.acceptableTypeIdentifiers ?? []) + [UTType.image.identifier])
    view.pasteDelegate = view
    view.backgroundColor = theme.uiColor(.surface).withAlphaComponent(0)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.font = AppTypography.font(.body)
    view.adjustsFontForContentSizeCategory = true
    view.delegate = context.coordinator
    view.accessibilityLabel = label
    view.accessibilityIdentifier = identifier
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.escape = { draft.dismissSuggestions() }
    return view
  }
  func updateUIView(_ view: ComposerInputView, context: Context) {
    // Native edits deliberately do not update this view; see ConversationDraft.editorRefresh.
    _ = draft.editorRefresh
    context.coordinator.parent = self
    view.composerOwner = owner
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    if view.isEditable != !draft.sending {
      // setEditable(false) also resigns focus. UIKit must not ask the SwiftUI
      // host for its next responder while that host is updating this view.
      DispatchQueue.main.async { [weak view, weak draft] in
        guard let view, let draft, view.representedDraft === draft else { return }
        if view.isEditable != !draft.sending { view.isEditable = !draft.sending }
      }
    }
    // A cover and its presenter coexist during dismissal; only one may own the keyboard.
    if draft.editorOwner == owner { draft.input = view }
    let focused = draft.focused && !draft.focusSuppressed && draft.editorOwner == owner
    view.requestFocus = focused
    view.submit = submit
    view.firstSuggestion = firstSuggestion
    view.importImages = importImages
    view.escape = { draft.dismissSuggestions() }
    view.canSubmit = canSubmit && draft.trigger == nil && draft.editorOwner == owner
    view.tintColor = theme.uiColor(.primary)
    let querying = draft.trigger != nil
    if view.querying != querying && view.markedTextRange == nil {
      view.querying = querying
      view.autocorrectionType = querying ? .no : .default
      view.autocapitalizationType = querying ? .none : .sentences
      view.spellCheckingType = querying ? .no : .default
      view.inlinePredictionType = querying ? .no : .default
      view.smartQuotesType = querying ? .no : .default
      view.smartDashesType = querying ? .no : .default
      view.smartInsertDeleteType = querying ? .no : .default
      if view.isFirstResponder { view.reloadInputViews() }
    }
    if view.markedTextRange == nil {
      let font = AppTypography.font(.body,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))
      let restyle = view.composerTheme.id != theme.id || view.composerFont != font
      view.composerTheme = theme
      view.composerFont = font
      if view.representedDraft !== draft || view.representedRevision != draft.sourceRevision {
        view.textStorage.setAttributedString(draft.editorText)
        view.representedDraft = draft
        view.representedRevision = draft.sourceRevision
        view.selectedRange = NSRange(location: min(draft.selection.location, view.textStorage.length),
                                     length: min(draft.selection.length, max(0, view.textStorage.length - draft.selection.location)))
        view.restyle()
        view.undoManager?.removeAllActions()
      } else if restyle {
        view.restyle()
      }
      resetTyping(view)
    } else {
      view.deferredUpdate = true
    }
    if focused && !view.isFirstResponder && view.window != nil {
      // Like resigning below: becoming first responder reloads the keyboard's input views,
      // which must not run inside this graph update (attribute cycle and a ~0.4 s hang).
      DispatchQueue.main.async { [weak view] in
        guard let view, view.requestFocus, !view.isFirstResponder, view.window != nil else { return }
        view.becomeFirstResponder()
      }
    }
    if !focused && view.isFirstResponder {
      // UIKit asks the SwiftUI host for its next responder. Doing that during a
      // graph update can cycle when the floating voice controls are present.
      DispatchQueue.main.async { [weak view] in
        guard let view, !view.requestFocus, view.isFirstResponder else { return }
        view.resignFirstResponder()
      }
    }
  }
  private func resetTyping(_ view: UITextView) {
    guard view.markedTextRange == nil else { return }
    view.typingAttributes = [.font: view.font ?? AppTypography.font(.body), .foregroundColor: theme.uiColor(.text)]
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerInputView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width else { return nil }
    if expanded {
      uiView.isScrollEnabled = true
      return CGSize(width: width, height: proposal.height ?? 240)
    }
    let line = uiView.composerFont.lineHeight
    // Asking sizeThatFits for an unbounded height lays out the entire draft on every edit.
    // TextKit already maintains contentSize for the visible scrolling editor.
    uiView.isScrollEnabled = true
    return CGSize(width: width, height: max(line + 2, min(line * 6 + 2, uiView.contentSize.height)))
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextView
    var updating = false
    init(_ parent: ComposerTextView) { self.parent = parent }
    func textViewDidBeginEditing(_ textView: UITextView) {
      if parent.draft.editorOwner == parent.owner { parent.draft.focused = true }
    }
    func textViewDidEndEditing(_ textView: UITextView) {
      if parent.draft.editorOwner == parent.owner { parent.draft.focused = false }
    }
    func textViewDidChange(_ textView: UITextView) {
      guard !updating, parent.draft.editorOwner == parent.owner else { return }
      guard let view = textView as? ComposerInputView else { return }
      parent.draft.receiveEditor(view)
      parent.resetTyping(textView)
      resumeDeferredUpdate(view)
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !updating, parent.draft.editorOwner == parent.owner else { return }
      guard let view = textView as? ComposerInputView, view.representedDraft === parent.draft else { return }
      parent.draft.selection = textView.selectedRange
      parent.resetTyping(textView)
      resumeDeferredUpdate(view)
    }
    private func resumeDeferredUpdate(_ view: ComposerInputView) {
      guard view.deferredUpdate, view.markedTextRange == nil else { return }
      view.deferredUpdate = false
      parent.draft.refreshEditor()
    }
    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      if text == "\n", let view = textView as? ComposerInputView {
        if view.submittedHardwareReturn || view.selectSuggestionOnReturn() || view.submitSoftwareReturn() {
          return false
        }
      }
      return true
    }
  }
}

final class ComposerInputView: UITextView {
  override var contentSize: CGSize {
    didSet {
      // TextKit can finish layout after SwiftUI's first size proposal, without a draft edit.
      if contentSize.height != oldValue.height { invalidateIntrinsicContentSize() }
    }
  }
  weak var representedDraft: ConversationDraft?
  var composerOwner: UUID?
  var representedRevision = -1
  // An update arrived during composition and skipped loading, restyling or keyboard traits.
  var deferredUpdate = false
  var composerTheme = AppTheme.selected
  var composerFont = AppTypography.font(.body)
  var plainAttributes: [NSAttributedString.Key: Any] {
    [.font: composerFont, .foregroundColor: composerTheme.uiColor(.text)]
  }
  func restyle() {
    let selection = selectedRange
    textStorage.beginEditing()
    textStorage.addAttributes(plainAttributes, range: NSRange(location: 0, length: textStorage.length))
    textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
      guard let attachment = value as? ComposerTokenAttachment else { return }
      textStorage.addAttribute(.attachment, value: ComposerTokenAttachment(attachment.token, theme: composerTheme, font: composerFont), range: range)
    }
    textStorage.endEditing()
    selectedRange = selection
  }
  func replaceCharacters(in range: NSRange, with value: NSAttributedString) {
    let previous = textStorage.attributedSubstring(from: range)
    let selection = selectedRange
    undoManager?.registerUndo(withTarget: self) { view in
      view.replaceCharacters(in: NSRange(location: range.location, length: value.length), with: previous)
      view.selectedRange = selection
      view.delegate?.textViewDidChangeSelection?(view)
    }
    textStorage.replaceCharacters(in: range, with: value)
    selectedRange = NSRange(location: range.location + value.length, length: 0)
    typingAttributes = plainAttributes
    delegate?.textViewDidChange?(self)
  }
  private static let pasteboardType = "br.com.alexandrem.opencode.composer"
  override func copy(_ sender: Any?) {
    guard selectedRange.length > 0 else { return }
    let document = ComposerDocument(editor: textStorage.attributedSubstring(from: selectedRange))
    var item: [String: Any] = ["public.utf8-plain-text": document.text]
    if let data = try? JSONEncoder().encode(document) { item[Self.pasteboardType] = data }
    UIPasteboard.general.setItems([item])
  }
  override func cut(_ sender: Any?) {
    guard isEditable, selectedRange.length > 0 else { return }
    copy(sender)
    replaceCharacters(in: selectedRange, with: NSAttributedString())
  }
  override func paste(_ sender: Any?) {
    guard isEditable else { return }
    let pasteboard = UIPasteboard.general
    if let data = pasteboard.data(forPasteboardType: Self.pasteboardType),
      let document = try? JSONDecoder().decode(ComposerDocument.self, from: data) {
      replaceCharacters(in: selectedRange, with: document.editorAttributed(theme: composerTheme, font: composerFont))
      return
    }
    // The edit menu, ⌘V and the keyboard's "Foto · Colar" suggestion all paste here: image items become
    // attachments and the other items' text is inserted, so nothing but text ever enters the editor.
    if pasteboard.hasImages, let importImages {
      let types = pasteboard.types(forItemSet: nil) ?? []
      let images = types.indices.filter { types[$0].contains { UTType($0)?.conforms(to: .image) == true } }
      let text = types.indices.filter { !images.contains($0) }.compactMap { Self.text(pasteboard, item: $0, types: types[$0]) }
      if !text.isEmpty { insertText(text.joined(separator: "\n")) }
      let providers = pasteboard.itemProviders
      importImages(images.filter { $0 < providers.count }.map { providers[$0] })
      return
    }
    // External rich text must not import arbitrary attachments or typing attributes.
    if let text = pasteboard.string { insertText(text) }
  }
  private static func text(_ pasteboard: UIPasteboard, item: Int, types: [String]) -> String? {
    if let type = types.first(where: { UTType($0)?.conforms(to: .plainText) == true }),
      let value = pasteboard.values(forPasteboardType: type, inItemSet: [item])?.first {
      return value as? String ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    guard let type = types.first(where: { UTType($0)?.conforms(to: .url) == true }),
      let value = pasteboard.values(forPasteboardType: type, inItemSet: [item])?.first else { return nil }
    return (value as? URL)?.absoluteString ?? value as? String
  }
  override func paste(itemProviders: [NSItemProvider]) {
    guard isEditable else { return }
    let images = itemProviders.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    if !images.isEmpty { importImages?(images) }
    let rest = itemProviders.filter { provider in !images.contains { $0 === provider } }
    if !rest.isEmpty { super.paste(itemProviders: rest) }
  }
  override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
    if importImages != nil, itemProviders.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
      return isEditable
    }
    return super.canPaste(itemProviders)
  }
  /// Rich insertions (for example from the keyboard) keep their text; image attachments become draft attachments.
  override func insertAttributedText(_ string: NSAttributedString) {
    var images: [NSItemProvider] = []
    let text = NSMutableString(string: string.string)
    string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length), options: .reverse) { value, range, _ in
      guard let attachment = value as? NSTextAttachment, !(attachment is ComposerTokenAttachment) else { return }
      text.deleteCharacters(in: range)
      if let image = attachment.image ?? attachment.contents.flatMap(UIImage.init(data:))
        ?? attachment.fileWrapper?.regularFileContents.flatMap(UIImage.init(data:)) {
        images.insert(NSItemProvider(object: image), at: 0)
      }
    }
    guard text.length != string.length else { return super.insertAttributedText(string) }
    if text.length > 0 { insertText(text as String) }
    if !images.isEmpty { importImages?(images) }
  }
  private var keyboardDismissal: CheckedContinuation<Void, Never>?
  private var keyboardObserver: (any NSObjectProtocol)?
  func dismissKeyboard() async {
    guard let window else { return }
    window.layoutIfNeeded()
    guard window.keyboardLayoutGuide.layoutFrame.height > window.safeAreaInsets.bottom + 1 else {
      resignFirstResponder()
      return
    }
    await withCheckedContinuation { continuation in
      keyboardDismissal = continuation
      keyboardObserver = NotificationCenter.default.addObserver(
        forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.finishKeyboardDismissal() }
      }
      resignFirstResponder()
    }
  }
  private func finishKeyboardDismissal() {
    if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
    keyboardObserver = nil
    keyboardDismissal?.resume()
    keyboardDismissal = nil
  }
  var escape: (() -> Void)?
  var importImages: (([NSItemProvider]) -> Void)?
  var firstSuggestion: (() -> (() -> Void)?)?
  func selectSuggestionOnReturn() -> Bool {
    let pick = firstSuggestion?()
    guard ComposerReturn.selectsSuggestion(
      markedText: markedTextRange != nil, suggestionsOpen: querying, firstItemReady: pick != nil), let pick
    else { return false }
    // Like a custom replacement in shouldChangeTextIn: the token replaces the query and UIKit drops the Return.
    pick()
    return true
  }
  var submit: (() -> Void)?
  var canSubmit = false
  private var hardwareSubmitted = false
  var submittedHardwareReturn: Bool { hardwareSubmitted }
  private lazy var submitCommand: UIKeyCommand = {
    let command = UIKeyCommand(
      input: "\r", modifierFlags: .shift, action: #selector(submitReturn(_:)))
    command.wantsPriorityOverSystemBehavior = true
    command.allowsAutomaticLocalization = false
    return command
  }()
  var requestFocus = false
  var querying = false
  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard let window else {
      finishKeyboardDismissal()
      return
    }
    // Install the public guide before focus changes so dismissal can inspect real visibility.
    _ = window.keyboardLayoutGuide
    // Insertion happens during SwiftUI/UIKit hierarchy updates; focus on the next turn.
    if requestFocus {
      DispatchQueue.main.async { [weak self] in
        guard let self, requestFocus, !isFirstResponder, self.window != nil else { return }
        becomeFirstResponder()
      }
    }
  }
  @discardableResult override func resignFirstResponder() -> Bool {
    hardwareSubmitted = false
    return super.resignFirstResponder()
  }
  override var keyCommands: [UIKeyCommand]? {
    let commands = [
      UIKeyCommand(
        input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissSuggestions))
    ]
    return (submit != nil ? [submitCommand] : [])
      + commands + (super.keyCommands ?? [])
  }
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(submitReturn(_:)) {
      return isFirstResponder && isEditable && canSubmit && !querying && markedTextRange == nil
        && submit != nil
    }
    // A plain-text view offers Paste only for text; an image is pasted as an attachment.
    if action == #selector(paste(_:)), isEditable, importImages != nil, UIPasteboard.general.hasImages { return true }
    return super.canPerformAction(action, withSender: sender)
  }
  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    hardwareSubmitted = false
    super.pressesEnded(presses, with: event)
  }
  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    hardwareSubmitted = false
    super.pressesCancelled(presses, with: event)
  }
  @objc private func submitReturn(_ command: UIKeyCommand) {
    guard !hardwareSubmitted, isFirstResponder, isEditable, !querying, markedTextRange == nil,
      canSubmit,
      let submit
    else { return }
    hardwareSubmitted = true
    submit()
  }
  func submitSoftwareReturn() -> Bool {
    guard !hardwareSubmitted, isFirstResponder, let submit else { return false }
    let shift = SoftwareKeyboardShift.state()
    guard
      ComposerReturn.shouldSubmit(
        shifted: shift?.shifted == true, autoShifted: shift?.automatic == true,
        shiftLocked: shift?.locked == true, available: shift != nil,
        markedText: markedTextRange != nil, suggestionsOpen: querying,
        canSubmit: canSubmit)
    else { return false }
    submit()
    return true
  }
  @objc private func dismissSuggestions() { escape?() }
}

extension ComposerInputView: UITextPasteDelegate {
  /// Drops and system item-provider pastes: an image never becomes a text attachment.
  func textPasteConfigurationSupporting(
    _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem
  ) {
    guard item.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
      return item.setDefaultResult()
    }
    importImages?([item.itemProvider])
    item.setNoResult()
  }
}
