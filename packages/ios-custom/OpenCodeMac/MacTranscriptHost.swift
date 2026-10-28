import AppKit
import OpenCodeKit
import SwiftUI

/// Mounts the conversation's transcript, like the iPhone's `TranscriptHost`: the view is kept with the conversation
/// (`TranscriptMemory.controller`), so coming back to it shows exactly what was left; if that view is still
/// mounted elsewhere, this mount builds a second one from the same store and memory.
struct MacTranscriptHost: NSViewControllerRepresentable {
  @Environment(\.appTheme) private var theme
  @AppStorage("OpenCodeCollapsibleUserMessages") private var collapsible = true
  let store: ConversationStore
  let sessions: SessionStore
  let quotes: ConversationQuoteContext
  let search: ConversationSearchHighlight
  let bottomPadding: CGFloat
  let configure: (MacTranscriptContext) -> Void

  func makeNSViewController(context: Context) -> MacTranscriptController {
    let memory = store.memory
    if let retained = memory.controller, !retained.mounted {
      retained.mount()
      return retained
    }
    let controller = MacTranscriptController(store: store, reading: sessions.reading, client: sessions.client)
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
