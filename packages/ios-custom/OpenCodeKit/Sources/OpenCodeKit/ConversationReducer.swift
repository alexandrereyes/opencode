import Foundation

public enum ConversationReducer {
  /// Returns false for structural/missing targets, so the caller revalidates the tail.
  @discardableResult public static func apply(
    _ event: ConversationEvent, to messages: inout [ConversationMessage]
  ) -> Bool {
    let data = event.data
    guard let id = data.assistantMessageID else { return false }
    if event.type == "session.step.started", !messages.contains(where: { $0.id == id }) {
      var message = ConversationMessage(
        id: id, type: "assistant", time: MessageTime(created: data.started ?? event.created ?? 0))
      message.agent = data.agent
      message.model = data.model
      message.content = []
      messages.append(message)
      return true
    }
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
    if event.type.hasPrefix("session.step.") {
      if event.type == "session.step.streamed" { messages[index].time.streamed = event.created }
      if event.type == "session.step.ended" || event.type == "session.step.failed" {
        messages[index].time.completed = event.created
        messages[index].finish = data.finish
        messages[index].tokens = data.tokens
        messages[index].error = data.error
      }
      return true
    }
    var parts = messages[index].content ?? []
    if event.type.hasPrefix("session.text.") || event.type.hasPrefix("session.reasoning.") {
      let kind = event.type.hasPrefix("session.text.") ? "text" : "reasoning"
      let positions = parts.indices.filter { parts[$0].type == ConversationPartKind(kind) }
      guard let ordinal = data.ordinal else { return false }
      if event.type.hasSuffix(".started") {
        guard ordinal == positions.count else { return ordinal < positions.count }
        parts.append(
          ConversationPart(
            type: kind, text: "",
            time: kind == "reasoning" ? MessageTime(created: event.created ?? 0) : nil))
      } else {
        guard positions.indices.contains(ordinal) else { return false }
        let position = positions[ordinal]
        if event.type.hasSuffix(".delta") {
          parts[position].text = (parts[position].text ?? "") + (data.delta?.string ?? "")
        }
        if event.type.hasSuffix(".ended") {
          parts[position].text = data.text
          parts[position].state = data.state
          parts[position].time?.completed = event.created
        }
      }
    } else if event.type.hasPrefix("session.tool.") {
      guard let toolID = data.id else { return false }
      if event.type == "session.tool.input.started", !parts.contains(where: { $0.id == toolID }) {
        parts.append(
          ConversationPart(
            type: "tool", id: toolID, name: data.name,
            state: .object(["status": .string("streaming"), "input": .string("")]),
            time: MessageTime(created: event.created ?? 0)))
      } else {
        guard let position = parts.firstIndex(where: { $0.id == toolID }) else { return false }
        var state = parts[position].state?.object ?? [:]
        switch event.type {
        case "session.tool.input.delta":
          state["input"] = .string((state["input"]?.string ?? "") + (data.delta?.string ?? ""))
        case "session.tool.input.ended": state["input"] = .string(data.text ?? "")
        case "session.tool.called":
          state["status"] = .string("running")
          state["input"] = data.input
          state["metadata"] = .object([:])
          parts[position].time?.ran = event.created
        case "session.tool.progress": state["metadata"] = data.metadata
        case "session.tool.success", "session.tool.failed":
          state["status"] = .string(event.type.hasSuffix("success") ? "completed" : "error")
          state["content"] = data.content
          state["metadata"] = data.metadata
          state["error"] = data.error
          parts[position].time?.completed = event.created
        default: return false
        }
        parts[position].state = .object(state)
      }
    } else {
      return false
    }
    messages[index].content = parts
    return true
  }
}
