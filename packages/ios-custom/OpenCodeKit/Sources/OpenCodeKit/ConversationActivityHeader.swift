import Foundation

/// The header of an activity card, shared by the iPhone and future Mac transcripts:
/// `Atividade · Ler, Shell e Editar · 3 ferramentas · 1m12s`. A group of reasoning alone reads
/// `Pensou 4s` (`Pensando` while it streams); one without tool calls or reasoning reads `Atualizações`.
public struct ConversationActivityHeader: Sendable, Equatable {
  public let title: String
  public let details: [String]
  public var label: String { ([title] + details).joined(separator: " · ") }

  /// `now` (epoch milliseconds) closes the span of members still running.
  public init(_ parts: [ConversationActivityPart], now: Double) {
    let tools = parts.filter { $0.part.type == .tool && (!$0.part.suppressed || $0.part.failed) }
    let reasoning = parts.filter { $0.part.type == .reasoning }
    if tools.isEmpty, !reasoning.isEmpty {
      if reasoning.contains(where: \.thinking) {
        self.init(title: "Pensando", details: [])
        return
      }
      let spans = reasoning.compactMap { entry in
        entry.part.time.flatMap { time in time.completed.map { $0 - time.created } }
      }
      if spans.count == reasoning.count {
        self.init(title: "Pensou \(ConversationProjection.duration((spans.reduce(0, +) / 1000).rounded() * 1000))", details: [])
        return
      }
      self.init(title: "Atividade", details: [reasoning.count == 1 ? "Raciocínio" : "Raciocínios"])
      return
    }
    guard !tools.isEmpty else {
      self.init(title: "Atividade", details: ["Atualizações"])
      return
    }
    var names: [String] = []
    for tool in tools where !names.contains(tool.part.groupTitle) { names.append(tool.part.groupTitle) }
    let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " e " + names.last! : names[0]
    let duration = Self.span(parts.map(\.part), now: now).map(ConversationProjection.duration)
    self.init(title: "Atividade",
      details: [list, tools.count == 1 ? "1 ferramenta" : "\(tools.count) ferramentas"] + (duration.map { [$0] } ?? []))
  }

  /// The header of loose parts, such as a direct shell message's call.
  public init(parts: [ConversationPart], now: Double) {
    self.init(parts.enumerated().map { ConversationActivityPart(id: $1.id ?? "\($0)", messageID: "", part: $1) }, now: now)
  }

  public init(title: String, details: [String]) {
    self.title = title
    self.details = details
  }

  /// Wall-clock time from the first member's start to the last member's end. Members without
  /// timestamps are ignored; a member that is neither finished nor running has no end.
  static func span(_ parts: [ConversationPart], now: Double) -> Double? {
    let ranges = parts.compactMap { part -> (Double, Double)? in
      guard let time = part.time else { return nil }
      guard let end = time.completed ?? (part.running ? now : nil) else { return nil }
      return (time.ran ?? time.created, end)
    }
    guard let start = ranges.map(\.0).min(), let end = ranges.map(\.1).max() else { return nil }
    return max(0, end - start)
  }
}

extension ConversationActivityRow {
  public func header(now: Double) -> ConversationActivityHeader { ConversationActivityHeader(parts, now: now) }
}

extension ConversationActivityItem {
  /// Finished without failing: a completed tool call, or a reasoning block that stopped streaming.
  /// The timeline draws these with the primary dot and every other state in gray.
  public var completed: Bool {
    parts.allSatisfy { entry in
      switch entry.part.type {
      case .tool: entry.part.status == "completed" && !entry.part.failed
      case .reasoning: !entry.thinking && entry.part.time?.completed != nil
      default: false
      }
    }
  }

  /// The members' own run times added together, only when every member has finished with timestamps.
  public var duration: Double? {
    let spans = parts.map { entry in
      entry.part.time.flatMap { time in time.completed.map { max(0, $0 - (time.ran ?? time.created)) } }
    }
    guard !spans.isEmpty, spans.allSatisfy({ $0 != nil }) else { return nil }
    return spans.compactMap { $0 }.reduce(0, +)
  }
}

extension ConversationPart {
  /// What a call acted on, shown in monospace beside its `groupTitle` in the activity timeline.
  public var activityTarget: String {
    if failed, status == "error" {
      let error = errorText?.replacingOccurrences(of: "Error: ", with: "") ?? "Falhou"
      return error.components(separatedBy: ": ").first ?? error
    }
    switch name {
    case "shell": return input["command"]?.string ?? metadata["command"]?.string ?? ""
    case "read": return readGroupName
    case "webfetch": return input["url"]?.string ?? ""
    case "websearch": return input["query"]?.string ?? ""
    case "iphone_query", "iphone_status":
      return name == "iphone_status" ? "estado"
        : input["source"]?.string.flatMap(DeviceSource.init(rawValue:))?.label ?? "dados"
    case "question":
      let question = input["questions"]?.array?.first?.object
      return question?["question"]?.string ?? question?["header"]?.string ?? ""
    default: return ""
    }
  }
}

extension ConversationProjection {
  /// When the running execution started: the first step after the latest `idle` boundary. Without a
  /// boundary in `messages`, only a complete history (`complete`) proves that the first step is the
  /// start; a partial page could hide an earlier one, so the time is unknown.
  public static func executionStarted(_ messages: [ConversationMessage], complete: Bool) -> Double? {
    let boundary = messages.lastIndex { $0.type == .idle }
    guard boundary != nil || complete else { return nil }
    return messages[(boundary.map { $0 + 1 } ?? 0)...].first { $0.type == .assistant }?.time.created
  }
}
