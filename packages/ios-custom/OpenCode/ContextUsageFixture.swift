#if DEBUG
import Foundation
import OpenCodeKit

enum ContextUsageFixture {
  static func snapshot(_ source: ScrollFixtureSnapshot) -> ScrollFixtureSnapshot {
    let model = source.models[0]
    let tokens = try! JSONDecoder().decode(TokenUsage.self, from: Data("""
      {"input":\(model.limit.context * 0.03),"output":\(model.limit.context * 0.035),
      "reasoning":0,"cache":{"read":\(model.limit.context * 0.315),"write":0}}
      """.utf8))
    let messages = source.messages.map { message in
      guard message.type == .assistant else { return message }
      var value = message
      value.model = ModelReference(id: model.id, providerID: model.providerID)
      value.tokens = tokens
      return value
    }
    return ScrollFixtureSnapshot(messages: messages, entries: source.entries, projects: source.projects,
      preferences: source.preferences, models: source.models)
  }
}
#endif
