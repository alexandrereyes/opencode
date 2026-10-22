import Foundation

public enum SubagentPreamble {
  // Exact prefix added by core/src/tool/plugin/subagent.ts for a newly spawned child.
  public static let prefix = "You are a subagent spawned by another session.\n"
  public static func stripping(_ text: String, isChild: Bool) -> String {
    guard isChild, text.hasPrefix(prefix) else { return text }
    return String(text.dropFirst(prefix.count))
  }
}

extension ConversationMessage {
  public func presented(isChild: Bool) -> Self {
    guard type == "user", isChild else { return self }
    var copy = self
    copy.metadata = metadata ?? [:]
    copy.metadata?["displayText"] = .string(SubagentPreamble.stripping(displayText, isChild: true))
    return copy
  }
}
