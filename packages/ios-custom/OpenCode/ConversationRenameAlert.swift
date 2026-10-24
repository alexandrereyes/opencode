import OpenCodeKit
import SwiftUI

extension OpenCodeClient {
  /// The conversation menu and the Sessões swipe share this request and its feedback.
  @MainActor func rename(_ sessionID: String, to change: SessionRename, toast: ToastCenter) async -> Bool {
    do {
      try await rename(sessionID, title: change.title)
      toast.show("Sessão renomeada")
      return true
    } catch {
      toast.show("Não foi possível renomear a sessão.", kind: .error)
      return false
    }
  }
}

struct ConversationRenameAlert: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let title: String
  let theme: AppTheme
  let save: (String) -> Void

  func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
  func updateUIViewController(_ controller: UIViewController, context: Context) {
    guard isPresented, controller.presentedViewController == nil, controller.view.window != nil else { return }
    let alert = UIAlertController(title: "Renomear sessão", message: nil, preferredStyle: .alert)
    alert.view.tintColor = theme.uiColor(.primary)
    alert.addTextField { field in
      field.text = title
      field.placeholder = "Título"
      field.keyboardType = .default
      field.autocapitalizationType = .sentences
      field.autocorrectionType = .yes
      field.spellCheckingType = .yes
      field.inlinePredictionType = .yes
      field.returnKeyType = .done
    }
    alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in isPresented = false })
    let confirm = UIAlertAction(title: "Salvar", style: .default) { [weak alert] _ in
      let value = alert?.textFields?.first?.text ?? ""
      isPresented = false
      save(value)
    }
    alert.addAction(confirm)
    // Return in the field triggers the preferred action.
    alert.preferredAction = confirm
    // UIAlertController focuses its field while presenting and leaves the caret at the end; selecting in the
    // completion runs after that, so typing replaces the whole title.
    controller.present(alert, animated: true) { [weak alert] in
      guard let field = alert?.textFields?.first, field.isFirstResponder || field.becomeFirstResponder() else { return }
      field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
    }
  }
}
