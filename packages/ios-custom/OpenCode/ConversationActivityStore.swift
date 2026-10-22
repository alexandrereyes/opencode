import OpenCodeKit

extension ConversationStore {
  func updateActivity() {
    let separate = Set(messages.flatMap(\.tools).filter { pendingTool($0) != nil }.compactMap(\.id))
    activity = ConversationActivity.project(messages, previous: activity, separateTools: separate, executing: executing)
  }
}
