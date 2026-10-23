import OpenCodeKit

extension ConversationStore {
  func updateActivity() {
    let boundary = reversion.boundary(session)
    activity = ConversationActivity.project(
      messages.filter { message in boundary.map { message.id < $0 } ?? true }, previous: activity, executing: executing)
  }
}
