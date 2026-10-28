import AppKit
import OpenCodeKit
import SwiftUI

/// Mounts the transcript retained by this window/session. The conversation data is shared, but each window has
/// its own controller, geometry and reading memory, so returning preserves its exact place.
struct MacTranscriptHost: NSViewControllerRepresentable {
  @Environment(\.appTheme) private var theme
  @AppStorage("OpenCodeCollapsibleUserMessages") private var collapsible = true
  let store: ConversationStore
  let sessions: SessionStore
  let memory: TranscriptMemory
  let reading: ReadingPositionStore
  let quotes: ConversationQuoteContext
  let search: ConversationSearchHighlight
  let bottomPadding: CGFloat
  let configure: (MacTranscriptContext) -> Void

  func makeNSViewController(context: Context) -> MacTranscriptController {
    if let retained = memory.controller, !retained.mounted {
      retained.mount()
      return retained
    }
    let controller = MacTranscriptController(store: store, memory: memory, reading: reading, client: sessions.client)
    if memory.controller == nil { memory.controller = controller }
    controller.mount()
    return controller
  }

  func updateNSViewController(_ controller: MacTranscriptController, context: Context) {
    controller.update(theme: theme, quotes: quotes, search: search, bottomPadding: bottomPadding,
      collapsible: collapsible)
    configure(controller.context)
    controller.canPersist = { [sessions, store] in !sessions.deletedIDs.contains(store.id) }
  }

  static func dismantleNSViewController(_ controller: MacTranscriptController, coordinator: ()) {
    controller.unmount()
  }
}
