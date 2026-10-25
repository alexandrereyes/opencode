import SwiftUI

struct SideQuestionInput: UIViewRepresentable {
  @Binding var text: String
  @Binding var focused: Bool
  let theme: AppTheme
  let canSubmit: Bool
  let submit: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> ComposerInputView {
    let view = ComposerInputView(frame: .zero, textContainer: nil)
    view.backgroundColor = theme.uiColor(.surface).withAlphaComponent(0)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.autocapitalizationType = .sentences
    view.delegate = context.coordinator
    view.accessibilityLabel = "Pergunte em paralelo…"
    view.accessibilityIdentifier = "side-question-composer"
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
  func updateUIView(_ view: ComposerInputView, context: Context) {
    context.coordinator.parent = self
    if view.text != text, view.markedTextRange == nil { view.text = text }
    view.textColor = theme.uiColor(.text)
    view.tintColor = theme.uiColor(.primary)
    view.submit = submit
    view.canSubmit = canSubmit
    view.requestFocus = focused
    // As in ComposerTextView: focus changes reload the keyboard's input views, which must not run
    // inside this graph update (attribute cycle and a ~0.4 s hang).
    if focused && !view.isFirstResponder && view.window != nil {
      DispatchQueue.main.async { [weak view] in
        guard let view, view.requestFocus, !view.isFirstResponder, view.window != nil else { return }
        view.becomeFirstResponder()
      }
    }
    if !focused && view.isFirstResponder {
      DispatchQueue.main.async { [weak view] in
        guard let view, !view.requestFocus, view.isFirstResponder else { return }
        view.resignFirstResponder()
      }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerInputView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width else { return nil }
    let line = UIFont.preferredFont(forTextStyle: .body).lineHeight
    let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    uiView.isScrollEnabled = height > line * 6
    return CGSize(width: width, height: max(line, min(line * 6, height)))
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: SideQuestionInput
    init(_ parent: SideQuestionInput) { self.parent = parent }
    func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
    func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard text == "\n", let view = textView as? ComposerInputView else { return true }
      return !view.submittedHardwareReturn && !view.submitSoftwareReturn()
    }
  }
}
