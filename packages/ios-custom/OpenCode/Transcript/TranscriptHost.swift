import OpenCodeKit
import SwiftUI

/// Mounts the conversation's transcript view. The view is kept with the conversation: mounting it again
/// shows exactly what it showed when left. If that view is still mounted elsewhere (the same conversation
/// twice on the stack), this mount builds a second one from the same store and memory instead.
struct TranscriptHost: UIViewControllerRepresentable {
  @Environment(\.appTheme) private var theme
  @Environment(\.conversationQuotes) private var quotes
  @Environment(\.conversationSearch) private var search
  @Environment(\.responseSelection) private var selection
  @Environment(\.responseSelectionChanged) private var selectionChanged
  @Environment(\.conversationImages) private var images
  @Environment(\.openFile) private var openFile
  @Environment(\.openImage) private var openImage
  @Environment(\.userMessageRevert) private var revert
  let store: ConversationStore
  let reading: ReadingPositionStore
  let size: CGSize?
  let bottomPadding: CGFloat
  let openChild: (String) -> Void
  let openNote: (TranscriptPart, String) -> Void
  let canPersist: () -> Bool
  var pagingSuspended = false

  func makeUIViewController(context: Context) -> TranscriptViewController {
    Self.mount(store, reading: reading)
  }

  /// The retained view when it is free; otherwise a second view from the same store and memory, opening at
  /// the passage last captured. Only the first is retained.
  static func mount(_ store: ConversationStore, reading: ReadingPositionStore) -> TranscriptViewController {
    let memory = store.memory
    if let retained = memory.controller, !retained.mounted {
      retained.mount()
      return retained
    }
    let controller = TranscriptViewController(store: store, reading: reading)
    if memory.controller == nil { memory.controller = controller }
    controller.mount()
    return controller
  }

  func updateUIViewController(_ controller: TranscriptViewController, context: Context) {
    controller.update(
      theme: theme, quotes: quotes, search: search, selection: selection, selectionChanged: selectionChanged,
      images: images, openFile: openFile, openImage: openImage, revert: revert, size: size,
      bottomPadding: bottomPadding)
    controller.context.openChild = openChild
    controller.context.openNote = openNote
    controller.canPersist = canPersist
    controller.pagingSuspended = pagingSuspended
  }

  static func dismantleUIViewController(_ controller: TranscriptViewController, coordinator: ()) {
    controller.unmount()
  }
}
