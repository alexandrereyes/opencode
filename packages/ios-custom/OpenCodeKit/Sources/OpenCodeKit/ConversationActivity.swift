import Foundation

public struct ConversationActivityPart: Sendable, Equatable, Identifiable {
  public let id: String
  public let messageID: String
  public let part: ConversationPart
  public let thinking: Bool
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
  public enum Kind: Sendable, Equatable { case text, group, tool, unknown }
  public let id: String
  public let kind: Kind
  public let parts: [ConversationActivityPart]
  public var busy = false
  public var label: String { ConversationProjection.stepLabel(parts.map(\.part)) }
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
    separateTools: Set<String> = [], executing: Bool = false
  ) -> ConversationActivity {
    var rows: [(owner: String, row: ConversationActivityRow)] = []
    var activity: [ConversationActivityPart] = []
    var boundary = 0
    func flush() {
      guard let first = activity.first else { return }
      rows.append((first.messageID, ConversationActivityRow(
        id: "context:\(first.messageID):\(first.id)", kind: .group, parts: activity)))
      activity = []
    }
    for message in messages {
      guard message.type == .assistant else {
        // Invisible execution markers and removed tools must not split visible activity.
        if message.type == .idle, message.outcome != "failed", message.outcome != "interrupted" { continue }
        flush()
        boundary = rows.count
        continue
      }
      for (index, part) in (message.content ?? []).enumerated() {
        if part.suppressed { continue }
        if (part.type == .text || part.type == .reasoning),
          part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { continue }
        guard let id = message.partID(at: index) else { continue }
        let thinking = executing && message.id == messages.last?.id && message.time.completed == nil
          && message.error == nil && message.retry == nil && part.type == .reasoning
          && index == (message.content?.count ?? 0) - 1 && part.time?.completed == nil
        let ref = ConversationActivityPart(id: id, messageID: message.id, part: part, thinking: thinking)
        let separate = part.type == .tool && (
          separateTools.contains(id)
            || ["question", "subagent", "task", "edit", "write", "patch", "apply_patch"].contains(part.name ?? ""))
        if part.type == .reasoning || (part.type == .tool && !separate) {
          activity.append(ref)
          continue
        }
        flush()
        // Pending questions have their own form card; they still delimit surrounding work.
        if part.name == "question", part.running { continue }
        rows.append((message.id, ConversationActivityRow(
          id: "part:\(message.id):\(id)", kind: part.type == .text ? .text : part.type == .tool ? .tool : .unknown,
          parts: [ref])))
      }
      if message.error != nil || message.retry != nil {
        flush()
        boundary = rows.count
      }
    }
    flush()
    if executing, messages.last?.type == .assistant, rows.count > boundary,
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
    let byMessage = Dictionary(grouping: rows, by: \.owner)
    var anchors: [String: String] = [:]
    for entry in rows {
      for part in entry.row.parts where anchors[part.messageID] == nil { anchors[part.messageID] = entry.owner }
    }
    let visible = messages.compactMap { message -> ConversationActivityMessage? in
      let content = byMessage[message.id]?.map(\.row) ?? []
      if message.type == .assistant && content.isEmpty && message.error == nil && message.retry == nil { return nil }
      if message.type == .idle && message.outcome != "failed" && message.outcome != "interrupted" { return nil }
      anchors[message.id] = message.id
      return ConversationActivityMessage(message: message, rows: content)
    }
    return ConversationActivity(messages: visible, anchors: anchors)
  }
}

extension ConversationPart {
  public var groupTitle: String {
    switch name {
    case "read": "Ler"
    case "list": "Listar"
    case "glob": "Glob"
    case "grep": "Grep"
    case "shell", "bash": "Shell"
    case "execute": "Execute"
    case "edit": "Editar"
    case "write": "Escrever"
    case "patch", "apply_patch": "Patch"
    case "skill": "Habilidade"
    case "subagent", "task": "Agente"
    case "webfetch": "Busca na web"
    case "websearch":
      metadata["provider"]?.string.flatMap { provider -> String? in
        if provider.isEmpty { return nil }
        let name = provider == "tinyfish" ? "TinyFish" : provider == "opencode" ? "OpenCode"
          : provider.prefix(1).uppercased() + provider.dropFirst()
        return "\(name) Pesquisa na web"
      } ?? "Pesquisa na web"
    case "question": "Perguntas"
    default: name ?? "Ferramenta"
    }
  }
}
