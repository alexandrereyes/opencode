import OpenCodeKit
import SwiftUI

/// Install on the native header without an overlay that would intercept expansion,
/// attachment taps or the prompt's internal scroll.
struct UserMessageCopyMenu: UIViewRepresentable {
  let message: ConversationMessage
  let toast: ToastCenter
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> Probe {
    Probe(interaction: UIContextMenuInteraction(delegate: context.coordinator))
  }
  func updateUIView(_ view: Probe, context: Context) {
    context.coordinator.parent = self
    view.attach()
  }
  static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { view.detach() }
  final class Probe: UIView {
    let interaction: UIContextMenuInteraction
    private weak var container: UICollectionReusableView?
    init(interaction: UIContextMenuInteraction) {
      self.interaction = interaction
      super.init(frame: .zero)
      isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { nil }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { detach(); return }
      attach()
    }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
    func attach() {
      guard window != nil else { return }
      var parent = superview
      while let current = parent {
        if let cell = current as? UICollectionReusableView {
          guard container !== cell else { return }
          detach()
          container = cell
          cell.addInteraction(interaction)
          return
        }
        parent = current.superview
      }
    }
    func detach() {
      container?.removeInteraction(interaction)
      container = nil
    }
  }
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
