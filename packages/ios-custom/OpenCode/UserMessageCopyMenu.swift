import OpenCodeKit
import SwiftUI

/// List's pinned section headers do not install SwiftUI contextMenu interactions.
/// Keep the native interaction on the bubble itself, with no retained transcript views.
struct UserMessageCopyMenu: UIViewRepresentable {
  let message: ConversationMessage
  let toast: ToastCenter
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
    return view
  }
  func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
  final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
    var parent: UserMessageCopyMenu
    init(_ parent: UserMessageCopyMenu) { self.parent = parent }
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      let message = parent.message
      let toast = parent.toast
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
        let copy = UIAction(title: "Copiar", image: UIImage(systemName: "doc.on.doc")) { _ in
          UIPasteboard.general.string = message.copyText
          Haptics.play(.selection)
          toast.show("Mensagem copiada")
        }
        let quote = UIAction(title: "Copiar citação", image: UIImage(systemName: "quote.opening")) {
          _ in
          UIPasteboard.general.string = message.copyQuotes
          Haptics.play(.selection)
          toast.show("Citação copiada")
        }
        return UIMenu(children: message.quotes.isEmpty ? [copy] : [copy, quote])
      }
    }
  }
}
