import OpenCodeKit
import SwiftUI

/// Install on the native header without an overlay that would intercept expansion,
/// attachment taps or the prompt's internal scroll.
struct UserMessageCopyMenu: UIViewRepresentable {
  @Environment(\.userMessageRevert) private var reversion
  @Environment(\.userMessagePending) private var pending
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
      let reversion = parent.reversion
      let pending = parent.pending
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
        var actions: [UIMenuElement] = message.quotes.isEmpty ? [copy] : [copy, quote]
        if let pending {
          let attributes: UIMenuElement.Attributes = pending.busy ? [.disabled] : []
          actions.append(UIAction(title: "Mover para a fila", image: UIImage(systemName: "arrow.down.to.line"),
            attributes: attributes) { _ in pending.queue() })
          actions.append(UIAction(title: "Excluir", image: UIImage(systemName: "trash"),
            attributes: attributes.union(.destructive)) { _ in pending.remove() })
        } else if let reversion {
          actions.append(UIAction(title: "Redefinir para este ponto", image: UIImage(systemName: "arrow.uturn.backward"),
            attributes: reversion.pending ? [.disabled] : []) { _ in reversion.revert(message.id) })
        }
        return UIMenu(children: actions)
      }
    }
  }
}

/// Copies the same text as the long-press "Copiar". Only this button re-renders while it shows ✓.
struct UserMessageCopyButton: View {
  let message: ConversationMessage
  @State private var copied = false
  var body: some View {
    Button {
      UIPasteboard.general.string = message.copyText
      Haptics.play(.light)
      copied = true
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc").appFont(.bubbleMeta)
        .frame(width: 28, height: 24)
        // A 48 × 44 pt target that adds no layout size.
        .contentShape(Rectangle().inset(by: -10))
    }.buttonStyle(.plain)
      .accessibilityLabel("Copiar mensagem").accessibilityValue(copied ? "Copiada" : "")
      .accessibilityIdentifier("user-copy-" + message.id)
      .task(id: copied) {
        guard copied else { return }
        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
        copied = false
      }
  }
}
