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
}

/// An undelivered steer below the transcript. Queued items live in the tray instead.
struct PendingUserMessage: View {
  @Environment(\.appTheme) private var theme
  let item: InboxItem
  let store: ConversationStore
  let maximumTextHeight: CGFloat
  let width: CGFloat
  var body: some View {
    let status = store.pendingStatus(item)
    UserBubble(message: item.message, maximumTextHeight: maximumTextHeight)
      .environment(\.appTheme, status?.waiting == true ? theme.pendingUserBubble : theme)
      .environment(\.userMessagePending, status.flatMap { status in
        guard status.actions else { return nil }
        return UserMessagePendingAction(
          status: status, busy: !store.actionable(item),
          queue: { Task { await store.moveToQueue(item) } },
          remove: { Task { await store.deletePending(item) } })
      })
      // Like the pinned header, a definite width lets the bubble measure its wrapping attachments.
      .frame(width: max(0, width - AppLayout.margin * 2))
      .padding(.vertical, 8).frame(maxWidth: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("pending-user-" + item.id)
      .accessibilityValue(status?.waiting == true ? "Pendente" : "")
  }
}
