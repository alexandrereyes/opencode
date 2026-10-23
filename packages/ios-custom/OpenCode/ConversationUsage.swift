import OpenCodeKit

extension ConversationStore {
  var sessionUsage: ContextUsage? {
    guard let message = ConversationProjection.latestMeasurement(messages) else { return nil }
    return usageCache.value(id: message.id, tokens: message.tokens, limit: usageLimit(message.model))
  }

  var totalUsage: ContextUsage? {
    usageCache.value(id: "session:" + id, tokens: session?.tokens, limit: nil)
  }

  func childUsage(_ id: String?) -> ContextUsage? {
    guard let context = children.first(where: { $0.id == id })?.context else { return nil }
    return usageCache.value(id: context.id, tokens: context.tokens, limit: usageLimit(context.model))
  }
}
