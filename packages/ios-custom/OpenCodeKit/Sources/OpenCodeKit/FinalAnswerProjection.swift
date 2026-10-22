import Foundation

extension ConversationProjection {
  /// Mirrors finalAnswerRowIndexes over the rows actually rendered by the native reader.
  public static func finalAnswerDividers(_ messages: [ConversationMessage]) -> Set<String> {
    struct TextRow {
      let id: String
      let messageID: String
      let index: Int
      let phase: String?
    }
    var result: Set<String> = []
    var pending: [TextRow] = []
    var activity: Int?
    var index = 0
    func flush() {
      let answer =
        pending.first { $0.phase == "final_answer" }
        ?? pending.first { $0.messageID == pending.last?.messageID }
      if let answer, let activity, answer.index > activity { result.insert(answer.id) }
      pending.removeAll()
    }
    func delimiter() {
      flush()
      activity = index
      index += 1
    }
    for message in messages {
      if message.type == "user" {
        flush()
        activity = nil
        index = 0
        continue
      }
      if message.type != "assistant" {
        if message.type != "idle" || message.outcome == "failed" || message.outcome == "interrupted"
        {
          delimiter()
        }
        continue
      }
      let eligible =
        message.finish == "stop" && message.time.completed != nil
        && message.error == nil && message.retry == nil
      for (ordinal, part) in (message.content ?? []).enumerated() {
        // Hidden successful todo parts (and empty text) are not projected activity.
        if part.type == "tool", part.name == "todowrite", part.status != "error" { continue }
        if part.type == "text", part.text?.isEmpty != false { continue }
        guard part.type == "text", eligible, let id = message.partID(at: ordinal) else {
          delimiter()
          continue
        }
        if activity == nil { activity = index }
        let phase = part.state?.object?["phase"]?.string
        if phase == "commentary", pending.contains(where: { $0.phase == "final_answer" }) {
          flush()
          activity = index
        }
        pending.append(TextRow(id: id, messageID: message.id, index: index, phase: phase))
        index += 1
      }
      if message.error != nil || message.retry != nil { delimiter() }
    }
    flush()
    return result
  }
}
