import Foundation

public struct ConversationActivityPart: Sendable, Equatable, Identifiable {
  public let id: String
  public let messageID: String
  public let part: ConversationPart
  public let thinking: Bool
  public var notice: ConversationMessage?
  public var reasoningLabel: String {
    if thinking { return "Pensando" }
    guard let time = part.time, let completed = time.completed else { return "Pensou" }
    return "Pensou \(ConversationProjection.duration(((completed - time.created) / 1000).rounded() * 1000))"
  }
  public init(id: String, messageID: String, part: ConversationPart, thinking: Bool = false) {
    self.id = id
    self.messageID = messageID
    self.part = part
    self.thinking = thinking
  }
}

public struct ConversationActivityRow: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable { case text, group, tool, divider, unknown }
  public let id: String
  public let kind: Kind
  public let parts: [ConversationActivityPart]
  public var items: [ConversationActivityItem] = []
  public var busy = false
  public var label: String { header(now: Date().timeIntervalSince1970 * 1000).label }
  public var pending: Bool { busy || parts.contains { $0.part.running || $0.thinking } }
}

public struct ConversationActivityMessage: Sendable, Equatable, Identifiable {
  public var id: String { message.id }
  public let message: ConversationMessage
  public let rows: [ConversationActivityRow]
}

/// Display groups span backend steps. Wire messages and their text/quote identities stay untouched.
public struct ConversationActivity: Sendable, Equatable {
  public let messages: [ConversationActivityMessage]
  public let anchors: [String: String]
  public static let empty = ConversationActivity(messages: [], anchors: [:])

  public static func project(
    _ messages: [ConversationMessage], previous: ConversationActivity = .empty,
    executing: Bool = false
  ) -> ConversationActivity {
    var rows: [(owner: String, row: ConversationActivityRow)] = []
    var activity: [ConversationActivityPart] = []
    var groupedMessages: Set<String> = []
    var shellTurn = false
    var terminalAssistants: Set<String> = []
    var lastAssistant: String?
    for message in messages {
      if message.type == .user || message.type == "shell" {
        if let lastAssistant { terminalAssistants.insert(lastAssistant) }
        lastAssistant = nil
      }
      if message.type == .assistant { lastAssistant = message.id }
    }
    if let lastAssistant { terminalAssistants.insert(lastAssistant) }
    var boundary = 0
    func flush() {
      guard let first = activity.first else { return }
      rows.append((first.messageID, ConversationActivityRow(
        id: "context:\(first.messageID):\(first.id)", kind: .group, parts: activity)))
      activity = []
    }
    for message in messages {
      guard message.type == .assistant else {
        if message.type == .idle { continue }
        if message.type == "synthetic", !visibleSynthetic(message) { continue }
        if !["user", "shell", "compaction", "model-switched", "location-switched"].contains(message.type.description) {
          var ref = ConversationActivityPart(id: message.id, messageID: message.id, part: ConversationPart(type: "notice"))
          ref.notice = message
          activity.append(ref)
          groupedMessages.insert(message.id)
          continue
        }
        flush()
        shellTurn = message.type == "shell"
        if message.type == "shell", let part = message.tools.first {
          activity.append(ConversationActivityPart(id: message.id, messageID: message.id, part: part))
          groupedMessages.insert(message.id)
        }
        boundary = rows.count
        continue
      }
      if shellTurn { flush(); shellTurn = false; boundary = rows.count }
      for (index, part) in (message.content ?? []).enumerated() {
        if part.suppressed && !part.failed { continue }
        if part.name == "question", part.running, !part.failed { continue }
        if (part.type == .text || part.type == .reasoning),
          part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { continue }
        guard let id = message.partID(at: index) else { continue }
        let thinking = executing && message.id == lastAssistant && message.time.completed == nil
          && message.error == nil && message.retry == nil && part.type == .reasoning
          && index == (message.content?.count ?? 0) - 1 && part.time?.completed == nil
        let ref = ConversationActivityPart(id: id, messageID: message.id, part: part, thinking: thinking)
        let separate = part.type == .tool && part.name == "question" && !part.failed
        if part.type == .reasoning || (part.type == .tool && !separate) {
          activity.append(ref)
          continue
        }
        flush()
        rows.append((message.id, ConversationActivityRow(
          id: "part:\(message.id):\(id)", kind: part.type == .text ? .text : part.type == .tool ? .tool : .unknown,
          parts: [ref])))
      }
      let errorType = message.error?.object?["type"]?.string?.lowercased() ?? ""
      if errorType.contains("abort") || errorType.contains("interrupt") {
        flush()
        rows.append((message.id, ConversationActivityRow(id: "interrupted:\(message.id)", kind: .divider, parts: [])))
        boundary = rows.count
      }
    }
    flush()
    if executing, rows.count > boundary,
      let index = rows.indices.last, rows[index].row.kind == .group {
      rows[index].row.busy = true
    }

    let prior = previous.messages.flatMap { item in
      item.rows.filter { $0.kind == .group }.map { (owner: item.id, row: $0) }
    }
    let byPart = Dictionary(prior.enumerated().flatMap { index, item in
      item.row.parts.map { ("\($0.messageID):\($0.id)", index) }
    }, uniquingKeysWith: { first, _ in first })
    let reserved = Dictionary(rows.enumerated().filter { $0.element.row.kind == .group }.map {
      ($0.element.row.id, $0.offset)
    }, uniquingKeysWith: { first, _ in first })
    var claimed: Set<String> = []
    rows = rows.enumerated().map { index, entry in
      guard entry.row.kind == .group else { return entry }
      // Prepending history can reveal an earlier first member or its real user. Reuse
      // the earliest surviving group without letting two split groups claim its key.
      let candidate = entry.row.parts.compactMap { byPart["\($0.messageID):\($0.id)"] }.filter {
        !claimed.contains(prior[$0].row.id) && (reserved[prior[$0].row.id] == nil || reserved[prior[$0].row.id] == index)
      }.min()
      guard let candidate else { return entry }
      let existing = prior[candidate]
      claimed.insert(existing.row.id)
      let owner = entry.row.parts.contains { $0.messageID == existing.owner } ? existing.owner : entry.owner
      return (owner, ConversationActivityRow(id: existing.row.id, kind: .group, parts: entry.row.parts, busy: entry.row.busy))
    }
    let previousItems = Dictionary(prior.map { ($0.row.id, $0.row.items) }, uniquingKeysWith: { first, _ in first })
    rows = rows.map { entry in
      var row = entry.row
      row.items = ConversationActivityItem.project(row.parts, previous: previousItems[row.id] ?? [])
      return (entry.owner, row)
    }
    let byMessage = Dictionary(grouping: rows, by: \.owner)
    var anchors: [String: String] = [:]
    for entry in rows {
      for part in entry.row.parts where anchors[part.messageID] == nil { anchors[part.messageID] = entry.owner }
    }
    let visible = messages.compactMap { source -> ConversationActivityMessage? in
      var message = source
      if !executing || message.id != lastAssistant { message.retry = nil }
      let errorType = message.error?.object?["type"]?.string?.lowercased() ?? ""
      if !terminalAssistants.contains(message.id) || errorType.contains("abort") || errorType.contains("interrupt") {
        message.error = nil
        message.retry = nil
      }
      let content = byMessage[message.id]?.map(\.row) ?? []
      if (message.type == .assistant || groupedMessages.contains(message.id)) && content.isEmpty && message.error == nil && message.retry == nil { return nil }
      if message.type == .idle { return nil }
      if message.type == "synthetic", !groupedMessages.contains(message.id) { return nil }
      anchors[message.id] = message.id
      return ConversationActivityMessage(message: message, rows: content)
    }
    return ConversationActivity(messages: visible, anchors: anchors)
  }

  private static func visibleSynthetic(_ message: ConversationMessage) -> Bool {
    if message.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
    if message.metadata?["state"]?.string == "error" { return true }
    return message.metadata?["source"]?.string == "shell" && message.metadata?["state"]?.string == "completed"
      && (message.metadata?["timeout"]?.bool == true || message.metadata?["exit"]?.number.map { $0 != 0 } == true)
  }
}

extension ConversationPart {
  public var groupTitle: String {
    switch name {
    case "read": "Ler"
    case "list": "Listar"
    case "glob": "Glob"
    case "grep": "Grep"
    case "shell": "Shell"
    case "execute": "Execute"
    case "edit": "Editar"
    case "write": "Escrever"
    case "patch": "Patch"
    case "skill": "Habilidade"
    case "subagent": "Agente"
    case "browser": "Navegador"
    case "webfetch": "Busca na web"
    case "websearch":
      metadata["provider"]?.string.flatMap { provider -> String? in
        if provider.isEmpty { return nil }
        let name = provider == "tinyfish" ? "TinyFish" : provider == "opencode" ? "OpenCode"
          : provider.prefix(1).uppercased() + provider.dropFirst()
        return "\(name) Pesquisa na web"
      } ?? "Pesquisa na web"
    case "question": "Perguntas"
    case "iphone_query", "iphone_status": "Consultou o iPhone"
    default: name ?? "Ferramenta"
    }
  }
}
