import OpenCodeKit

extension ConversationStore {
  func updateActivity() {
    let visible = SessionRevert.visible(messages, boundary: reversion.boundary(session))
    // Assigning an equal index publishes nothing; mutating it in place would invalidate every observer.
    var index = quoteIndex
    index.update(visible)
    quoteIndex = index
    activity = ConversationActivity.project(visible, previous: activity, executing: executing)
  }
}
