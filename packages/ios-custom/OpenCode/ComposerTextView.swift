import OpenCodeKit
import SwiftUI

struct ComposerTextView: UIViewRepresentable {
  @Bindable var draft: ConversationDraft
  let theme: AppTheme
  var expanded: Bool
  let owner: UUID
  let expand: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> ComposerInputView {
    let view = ComposerInputView(usingTextLayoutManager: true)
    view.backgroundColor = theme.uiColor(.surface).withAlphaComponent(0)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.delegate = context.coordinator
    view.accessibilityLabel = "Mensagem"
    view.accessibilityIdentifier = "conversation-composer"
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.escape = { draft.dismissSuggestions() }
    let toolbar = UIToolbar()
    toolbar.items = [
      UIBarButtonItem(
        image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"), style: .plain,
        target: context.coordinator, action: #selector(Coordinator.expand)),
      .flexibleSpace(),
      UIBarButtonItem(
        title: "Concluir", style: .prominent,
        target: context.coordinator, action: #selector(Coordinator.dismissKeyboard)),
    ]
    toolbar.items?.first?.accessibilityLabel = "Expandir compositor"
    toolbar.sizeToFit()
    // iOS's floating toolbar leaves its backdrop transparent; keep transcript text
    // from painting between the keyboard and composer.
    let accessory = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: toolbar.bounds.height))
    toolbar.frame = accessory.bounds
    toolbar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    accessory.addSubview(toolbar)
    view.inputAccessoryView = accessory
    return view
  }
  func updateUIView(_ view: ComposerInputView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    view.isEditable = !draft.sending
    // A cover and its presenter coexist during dismissal; only one may own the keyboard.
    let focused = draft.focused && draft.editorOwner == owner
    view.requestFocus = focused
    view.tintColor = theme.uiColor(.primary)
    view.inputAccessoryView?.backgroundColor = theme.uiColor(.background)
    if let toolbar = view.inputAccessoryView?.subviews.first as? UIToolbar {
      let appearance = UIToolbarAppearance()
      appearance.configureWithOpaqueBackground()
      appearance.backgroundColor = theme.uiColor(.background)
      toolbar.standardAppearance = appearance
      toolbar.scrollEdgeAppearance = appearance
      toolbar.tintColor = theme.uiColor(.primary)
      toolbar.items?.first?.image = UIImage(
        systemName: expanded
          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
      toolbar.items?.first?.accessibilityLabel =
        expanded ? "Recolher compositor" : "Expandir compositor"
    }
    let value = NSMutableAttributedString(attributedString: draft.document.attributed)
    if value.length > 0 {
      value.addAttributes(
        [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: theme.uiColor(.text)],
        range: NSRange(location: 0, length: value.length))
      for span in draft.document.validTokens {
        value.addAttributes(
          [
            .foregroundColor: theme.uiColor(span.token.kind.role),
            .backgroundColor: theme.uiColor(span.token.kind.role).withAlphaComponent(0.12),
          ], range: span.range)
      }
    }
    if view.markedTextRange == nil && !view.attributedText.isEqual(to: value) {
      view.attributedText = value
    }
    if NSMaxRange(draft.selection) <= value.length, view.selectedRange != draft.selection {
      view.selectedRange = draft.selection
    }
    resetTyping(view)
    if focused && !view.isFirstResponder && view.window != nil { view.becomeFirstResponder() }
    if !focused && view.isFirstResponder { view.resignFirstResponder() }
  }
  private func resetTyping(_ view: UITextView) {
    view.typingAttributes = [
      .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: theme.uiColor(.text),
    ]
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerInputView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width else { return nil }
    if expanded {
      uiView.isScrollEnabled = true
      return CGSize(width: width, height: proposal.height ?? 240)
    }
    let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
    let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    uiView.isScrollEnabled = fitting.height > line * 6 + 2
    return CGSize(width: width, height: max(line + 2, min(line * 6 + 2, fitting.height)))
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
      parent.draft.selection = textView.selectedRange
      parent.draft.text = textView.attributedText
      parent.resetTyping(textView)
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !updating, parent.draft.editorOwner == parent.owner else { return }
      let selection = textView.selectedRange
      if selection.length == 0,
        let span = parent.draft.document.validTokens.first(where: {
          selection.location > $0.start && selection.location < $0.end
        })
      {
        textView.selectedRange = NSRange(
          location: selection.location < parent.draft.selection.location ? span.start : span.end,
          length: 0)
        return
      }
      parent.draft.selection = selection
      parent.resetTyping(textView)
    }
    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      let overlaps = parent.draft.document.validTokens.filter {
        NSIntersectionRange(range, $0.range).length > 0
          || (range.length == 0 && range.location > $0.start && range.location < $0.end)
      }
      guard !overlaps.isEmpty else { return true }
      let start = min(range.location, overlaps.map(\.start).min() ?? range.location)
      let end = max(NSMaxRange(range), overlaps.map(\.end).max() ?? NSMaxRange(range))
      let value = NSMutableAttributedString(attributedString: textView.attributedText)
      value.replaceCharacters(
        in: NSRange(location: start, length: end - start), with: NSAttributedString(string: text))
      parent.draft.selection = NSRange(location: start + text.utf16.count, length: 0)
      parent.draft.text = value
      return false
    }
    @objc func dismissKeyboard() { parent.draft.focused = false }
    @objc func expand() { parent.expand() }
  }
}

final class ComposerInputView: UITextView {
  var escape: (() -> Void)?
  var requestFocus = false
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil && requestFocus { becomeFirstResponder() }
  }
  override var keyCommands: [UIKeyCommand]? {
    (super.keyCommands ?? []) + [
      UIKeyCommand(
        input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissSuggestions))
    ]
  }
  @objc private func dismissSuggestions() { escape?() }
}
