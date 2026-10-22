import SwiftUI

struct ConversationSearchField: UIViewRepresentable {
  @Binding var text: String
  let theme: AppTheme
  let next: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(text: $text, next: next) }
  func makeUIView(context: Context) -> Field {
    let field = Field()
    field.placeholder = "Buscar na conversa"
    field.accessibilityIdentifier = "conversation-search"
    field.autocorrectionType = .no
    field.autocapitalizationType = .none
    field.returnKeyType = .search
    field.delegate = context.coordinator
    field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
    return field
  }
  func updateUIView(_ field: Field, context: Context) {
    context.coordinator.text = $text
    context.coordinator.next = next
    if field.text != text { field.text = text }
    field.textColor = theme.uiColor(.textStrong)
    field.backgroundColor = theme.uiColor(.codeSurface)
    field.tintColor = theme.uiColor(.primary)
    field.leftView?.tintColor = theme.uiColor(.icon)
  }
  static func dismantleUIView(_ view: Field, coordinator: Coordinator) {
    view.resignFirstResponder()
    view.delegate = nil
  }
  final class Field: UISearchTextField {
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { becomeFirstResponder() }
    }
  }
  final class Coordinator: NSObject, UITextFieldDelegate {
    var text: Binding<String>
    var next: () -> Void
    init(text: Binding<String>, next: @escaping () -> Void) {
      self.text = text
      self.next = next
    }
    @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { next(); return false }
  }
}
