import SwiftUI

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
      field.autocapitalizationType = .sentences
      field.autocorrectionType = .no
      field.spellCheckingType = .no
    }
    alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in isPresented = false })
    alert.addAction(UIAlertAction(title: "Salvar", style: .default) { [weak alert] _ in
      let value = alert?.textFields?.first?.text ?? ""
      isPresented = false
      save(value)
    })
    controller.present(alert, animated: true)
  }
}
