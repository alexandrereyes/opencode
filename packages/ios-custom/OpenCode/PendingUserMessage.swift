import OpenCodeKit
import SwiftUI

/// The web's pending-steer actions: they replace the sent-message actions until delivery.
struct UserMessagePendingAction {
  let status: PendingInputStatus
  let busy: Bool
  let queue: () -> Void
  let remove: () -> Void
}

extension EnvironmentValues {
  @Entry var userMessagePending: UserMessagePendingAction? = nil
  @Entry var userMessageUndelivered = false
}

/// An undelivered steer below the transcript. Queued items live in the tray instead.
/// Unlike the web, which keeps the sent accent while `starting`, every undelivered bubble uses
/// the pending style and label from the tap until delivery (Alexandre, 24/10).
struct PendingUserMessage: View {
  @Environment(\.appTheme) private var theme
  let item: InboxItem
  let store: ConversationStore
  let maximumTextHeight: CGFloat
  var body: some View {
    let status = store.pendingStatus(item)
    UserBubble(message: item.message, maximumTextHeight: maximumTextHeight)
      .environment(\.appTheme, theme.pendingUserBubble)
      .environment(\.userMessageUndelivered, true)
      .environment(\.userMessagePending, status.flatMap { status in
        guard status.actions else { return nil }
        return UserMessagePendingAction(
          status: status, busy: !store.actionable(item),
          queue: { Task { await store.moveToQueue(item) } },
          remove: { Task { await store.deletePending(item) } })
      })
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("pending-user-" + item.id)
      .accessibilityValue("Pendente")
  }
}
