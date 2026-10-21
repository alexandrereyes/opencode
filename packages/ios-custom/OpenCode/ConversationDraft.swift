import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class ConversationDraft {
  var text = NSAttributedString()
  var model: ModelReference?
  var agent: String?
  var editing: InboxItem?
  var sending = false
  var error: String?
  var submission: PromptSubmission?

  func restore(_ item: InboxItem) {
    text = NSAttributedString(string: item.payload.displayText)
    editing = item
    submission = nil
    error = nil
    agent = item.payload.metadata?["agent"]?.string
    if let value = item.payload.metadata?["model"]?.object,
      let id = value["modelID"]?.string, let provider = value["providerID"]?.string
    {
      model = ModelReference(id: id, providerID: provider, variant: value["variant"]?.string)
    }
  }
}

@MainActor final class ConversationDrafts {
  private var values: [String: ConversationDraft] = [:]
  func draft(_ id: String) -> ConversationDraft {
    if let draft = values[id] { return draft }
    let draft = ConversationDraft()
    values[id] = draft
    return draft
  }
}
