import SwiftUI

struct ConversationOptionsMenu: UIViewRepresentable {
  let sessionID: String
  let available: Bool
  let canArchive: Bool
  let archiving: Bool
  let theme: AppTheme
  let actions: Actions

  struct Actions {
    let search: () -> Void
    let rename: () -> Void
    let details: () -> Void
    let archive: () -> Void
  }
  struct Signature: Equatable {
    let sessionID: String
    let available: Bool
    let canArchive: Bool
    let archiving: Bool
    let theme: String
  }
  final class Coordinator {
    var signature: Signature?
    var actions: Actions?
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    button.showsMenuAsPrimaryAction = true
    button.accessibilityLabel = "Mais opções"
    return button
  }
  func updateUIView(_ button: UIButton, context: Context) {
    update(button, coordinator: context.coordinator)
  }
  func update(_ button: UIButton, coordinator: Coordinator) {
    coordinator.actions = actions
    let signature = Signature(sessionID: sessionID, available: available, canArchive: canArchive,
                              archiving: archiving, theme: theme.id)
    guard coordinator.signature != signature else { return }
    coordinator.signature = signature
    button.tintColor = theme.uiColor(.primary)
    button.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19))?
      .withTintColor(theme.uiColor(.textStrong), renderingMode: .alwaysOriginal), for: .normal)
    func icon(_ name: String) -> UIImage? {
      UIImage(systemName: name)?.withTintColor(theme.uiColor(.primary), renderingMode: .alwaysOriginal)
    }
    // Keep the menu and native actions alive across unrelated header/transcript
    // updates. Their handlers read the latest callbacks, not a discarded View body.
    let search = UIAction(title: "Buscar na conversa", image: icon("magnifyingglass")) {
      [weak coordinator] _ in coordinator?.actions?.search()
    }
    let rename = UIAction(title: "Renomear", image: icon("pencil"), attributes: available ? [] : .disabled) {
      [weak coordinator] _ in coordinator?.actions?.rename()
    }
    let details = UIAction(title: "Detalhes da sessão", image: icon("info.circle"), attributes: available ? [] : .disabled) {
      [weak coordinator] _ in coordinator?.actions?.details()
    }
    let archive = UIAction(title: "Arquivar", image: icon("archivebox"),
                          attributes: available && !archiving ? .destructive : [.destructive, .disabled]) {
      [weak coordinator] _ in coordinator?.actions?.archive()
    }
    button.menu = UIMenu(children: [search, rename, details] + (canArchive
      ? [UIMenu(options: .displayInline, children: [archive])] : []))
  }
  static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
    button.menu = nil
    coordinator.actions = nil
    coordinator.signature = nil
  }
}
