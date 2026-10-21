import Foundation

public struct ModelReference: Codable, Sendable, Hashable {
  public var id: String
  public var providerID: String
  public var variant: String?
  public init(id: String, providerID: String, variant: String? = nil) {
    self.id = id
    self.providerID = providerID
    self.variant = variant
  }
}

public struct ModelInfo: Codable, Sendable {
  public let id: String
  public let providerID: String
  public let name: String
  public let enabled: Bool?
  public let variants: [Variant]?
  public let limit: Limit
  public var identity: String { "\(providerID)/\(id)" }
  public struct Variant: Codable, Sendable, Identifiable { public let id: String }
  public struct Limit: Codable, Sendable { public let context: Double }
}

public struct ProviderInfo: Codable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct AgentInfo: Codable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let color: String?
  public let mode: String
  public let hidden: Bool?
  public let model: ModelReference?
}

public struct TokenUsage: Codable, Sendable, Hashable {
  public var input: Double
  public var output: Double
  public var reasoning: Double
  public var cache: Cache
  public struct Cache: Codable, Sendable, Hashable {
    public var read: Double
    public var write: Double
  }
  public var total: Double { input + output + reasoning + cache.read + cache.write }
}

public struct MessageTime: Codable, Sendable, Equatable {
  public var created: Double
  public var ran: Double?
  public var streamed: Double?
  public var completed: Double?
}

/// Unknown message and part types retain their tag rather than failing the whole page.
public struct ConversationMessage: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var type: ConversationMessageKind
  public var time: MessageTime
  public var text: String?
  public var description: String?
  public var agent: String?
  public var model: ModelReference?
  public var content: [ConversationPart]?
  public var tokens: TokenUsage?
  public var finish: String?
  public var error: JSONValue?
  public var retry: JSONValue?
  public var metadata: [String: JSONValue]?
  public var files: [JSONValue]?
  public var status: String?
  public var outcome: String?
  public var command: String?
  public var output: String?
  public var name: String?
  public var summary: String?
  public var shellID: String?
  public var exit: Int?

  public init(id: String, type: String, time: MessageTime) {
    self.id = id
    self.type = ConversationMessageKind(type)
    self.time = time
  }
  public var displayText: String { metadata?["displayText"]?.string ?? text ?? "" }
  public var responseText: String {
    (content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n\n")
  }
  public var tools: [ConversationPart] {
    if type == "shell" {
      return [
        ConversationPart(
          type: "tool", id: shellID ?? id, name: "shell",
          state: .object([
            "status": .string(status == "running" ? "running" : "completed"),
            "input": .object(["command": .string(command ?? "")]),
            "content": .array([.object(["type": .string("text"), "text": .string(output ?? "")])]),
            "metadata": .object(exit.map { ["exit": .number(Double($0))] } ?? [:]),
          ]), time: time)
      ]
    }
    return (content ?? []).filter { $0.type == "tool" }
  }
  public func partID(at index: Int) -> String? {
    guard let content, content.indices.contains(index) else { return nil }
    let part = content[index]
    if part.type == "tool" { return part.id }
    return "\(id):\(part.type):\(content[..<index].filter { $0.type == part.type }.count)"
  }
  public var notice: String {
    switch type {
    case "synthetic", "system": description ?? text ?? "Aviso da sessão"
    case "agent-switched": "Agente alterado para \(agent ?? "outro agente")"
    case "model-switched": "Modelo alterado para \(model?.id ?? "outro modelo")"
    case "location-switched": "Diretório de trabalho alterado"
    case "compaction":
      status == "running"
        ? "Resumindo contexto…"
        : status == "failed" ? "Falha ao resumir contexto" : "Contexto resumido"
    case "skill": "Skill · \(name ?? "")"
    case "shell": "$ \(command ?? "")\n\(output ?? "")"
    case "idle": outcome == "interrupted" ? "Execução interrompida" : "Execução concluída"
    default: text ?? description ?? "Aviso · \(type)"
    }
  }
}

public struct ConversationPart: Codable, Sendable, Equatable {
  public var type: ConversationPartKind
  public var id: String?
  public var name: String?
  public var text: String?
  public var state: JSONValue?
  public var time: MessageTime?
  public init(
    type: String, id: String? = nil, name: String? = nil, text: String? = nil,
    state: JSONValue? = nil, time: MessageTime? = nil
  ) {
    self.type = ConversationPartKind(type)
    self.id = id
    self.name = name
    self.text = text
    self.state = state
    self.time = time
  }
  public var status: String? { state?.object?["status"]?.string }
  public var input: [String: JSONValue] { state?.object?["input"]?.object ?? [:] }
  public var metadata: [String: JSONValue] { state?.object?["metadata"]?.object ?? [:] }
  public var childID: String? { metadata["sessionID"]?.string }
  public var running: Bool { status == "running" || status == "streaming" }
  public var failed: Bool {
    if status == "error" { return true }
    guard name == "execute" else { return false }
    return metadata["error"]?.bool == true
      || metadata["toolCalls"]?.array?.contains {
        $0.object?["status"]?.string == "error" || $0.object?["status"]?.string == "failed"
          || ($0.object?["error"] != nil && $0.object?["error"] != .null)
      } == true
  }
  public var output: String {
    state?.object?["content"]?.array?.compactMap { $0.object?["text"]?.string }.joined(
      separator: "\n")
      ?? metadata["output"]?.string ?? ""
  }
  public var errorText: String? { state?.object?["error"]?.object?["message"]?.string }
  public var diffs: [[String: JSONValue]] { metadata["files"]?.array?.compactMap(\.object) ?? [] }
  public var category: String {
    switch name {
    case "read": "Leu"
    case "shell": "Rodou"
    case "edit", "write", "patch": "Editou"
    case "subagent": "Agente"
    case "glob", "grep": "Buscou"
    case "websearch": "Pesquisou"
    case "webfetch": "Abriu"
    case "execute": "execute"
    case "question": "Perguntou"
    case "skill": "Skill"
    default: name ?? "Ferramenta"
    }
  }
  public var icon: String {
    switch name {
    case "glob", "grep": "magnifyingglass"
    case "websearch": "globe"
    case "webfetch": "link"
    case "question": "questionmark.bubble"
    case "shell": "terminal"
    case "read": "doc.text"
    case "edit", "write", "patch": "pencil"
    default: "wrench.and.screwdriver"
    }
  }
  public var exitCode: Int? {
    guard name == "shell", status == "completed", let exit = metadata["exit"]?.number, exit != 0
    else { return nil }
    return Int(exit)
  }
  public var diffLines: [String] {
    diffs.flatMap { Self.patchLines($0["patch"]?.string ?? "") }
  }
  public static func patchLines(_ patch: String) -> [String] {
    patch.components(separatedBy: "\n").filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }
  }
  public func elapsed(now: Double) -> String? {
    guard let time else { return nil }
    return ConversationProjection.duration((time.completed ?? now) - (time.ran ?? time.created))
  }
  public func summary(now: Double) -> String {
    let path = input["path"]?.string ?? input["filePath"]?.string ?? "arquivo"
    let failed = self.failed ? " · falhou" : ""
    switch name {
    case "read":
      let count = output.firstMatch(of: /(?m)^Read file .+, lines (\d+)-(\d+)/).flatMap {
        guard let start = Int($0.1), let end = Int($0.2) else { return nil as Int? }
        return max(0, end - start + 1)
      }
      return "Leu \(path)\(count.map { " · \($0) linhas" } ?? "")\(failed)"
    case "shell":
      return
        "\(running ? "Rodando" : "Rodou") \(input["command"]?.string ?? metadata["command"]?.string ?? "comando")\(elapsed(now: now).map { " · \($0)" } ?? "")\(failed)"
    case "edit", "write", "patch":
      let files = diffs
      let counts =
        files.isEmpty
        ? ""
        : " +\(Int(files.reduce(0) { $0 + ($1["additions"]?.number ?? 0) })) −\(Int(files.reduce(0) { $0 + ($1["deletions"]?.number ?? 0) }))"
      return "Editou \(files.first?["file"]?.string ?? path)\(counts)\(failed)"
    case "glob": return "Buscou arquivos \(input["pattern"]?.string ?? "")\(failed)"
    case "grep": return "Buscou \"\(input["pattern"]?.string ?? "")\"\(failed)"
    case "websearch": return "Pesquisou \(input["query"]?.string ?? "")\(failed)"
    case "webfetch":
      let url = input["url"]?.string.flatMap(URL.init(string:))
      return
        "Abriu \(url.map { ($0.host ?? "") + $0.path } ?? input["url"]?.string ?? "página web")\(failed)"
    case "skill":
      return
        "Skill · \(metadata["name"]?.string ?? input["id"]?.string ?? input["name"]?.string ?? "skill")\(failed)"
    case "subagent": return input["description"]?.string ?? "Subagente"
    case "question":
      let question = input["questions"]?.array?.first?.object
      return
        "Perguntou\((question?["question"]?.string ?? question?["header"]?.string).map { ": \($0)" } ?? "")\(failed)"
    default:
      let input = self.input.sorted { $0.key < $1.key }.map { key, value in
        "\(key): \(value.string ?? value.formatted)"
      }.joined(separator: ", ")
      return "\(name ?? "Ferramenta")\(input.isEmpty ? "" : " · \(input.prefix(80))")\(failed)"
    }
  }
}

public struct ConversationPage: Codable, Sendable {
  public let data: [ConversationMessage]
  public let cursor: Cursor?
  public struct Cursor: Codable, Sendable {
    public let next: String?
    public let previous: String?
  }
}

public struct FamilyPage: Codable, Sendable {
  public let data: [Session]
  public let next: String?
}
public struct ShellInfo: Codable, Sendable {
  public let id: String
  public let status: String
  public let command: String
  public let metadata: [String: JSONValue]?
  public let time: Time
  public struct Time: Codable, Sendable { public let started: Double }
}
public struct ShellOutput: Codable, Sendable {
  public let output: String
  public let cursor: Int
  public let size: Int
  public let truncated: Bool
}

public enum ConversationProjection {
  public static func followTail(current: Bool, interacting: Bool, nearBottom: Bool) -> Bool {
    interacting ? nearBottom : current || nearBottom
  }
  public static func duration(_ milliseconds: Double) -> String {
    let seconds = max(0, Int(milliseconds / 1000))
    if seconds >= 86400 {
      let hours = seconds % 86400 / 3600
      return "\(seconds / 86400)d\(hours == 0 ? "" : " \(hours)h")"
    }
    if seconds >= 3600 {
      let minutes = seconds % 3600 / 60
      return "\(seconds / 3600)h\(minutes == 0 ? "" : "\(minutes)m")"
    }
    return seconds >= 60 ? "\(seconds / 60)m\(seconds % 60)s" : "\(seconds)s"
  }
  public static func context(_ messages: [ConversationMessage], models: [ModelInfo]) -> Double? {
    guard let message = messages.last(where: { $0.type == "assistant" && $0.tokens != nil }),
      let tokens = message.tokens,
      let model = models.first(where: {
        $0.id == message.model?.id && $0.providerID == message.model?.providerID
      }), model.limit.context > 0
    else { return nil }
    return tokens.total / model.limit.context
  }
  public static func stepLabel(_ parts: [ConversationPart]) -> String {
    let tools = parts.filter {
      $0.type == "tool" && ($0.name != "todowrite" || $0.status == "error")
    }
    let count = tools.isEmpty ? parts.filter { $0.type == "reasoning" }.count : tools.count
    if count == 0 { return "Atividade" }
    var names: [String] = []
    for tool in tools where !names.contains(tool.category) { names.append(tool.category) }
    let list =
      names.count > 3
      ? names.prefix(3).joined(separator: ", ") + " e mais \(names.count - 3)"
      : names.count > 1
        ? names.dropLast().joined(separator: ", ") + " e " + names.last!
        : names.first ?? "Raciocínio"
    return "Usou \(count) · \(list)"
  }
  public static func footer(_ message: ConversationMessage, models: [ModelInfo]) -> String {
    let model = models.first {
      $0.id == message.model?.id && $0.providerID == message.model?.providerID
    }
    return [
      model?.name ?? message.model?.id,
      message.model?.variant == "default" ? nil : message.model?.variant,
      date(message.time.completed ?? message.time.created, format: "dd/MM HH:mm"),
    ].compactMap { $0 }.joined(separator: " · ")
  }
  public static func date(_ milliseconds: Double, format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.dateFormat = format
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
  }
  public static func day(_ milliseconds: Double, now: Date = .now, calendar: Calendar = .current)
    -> String
  {
    let date = Date(timeIntervalSince1970: milliseconds / 1000)
    let days =
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
      ).day ?? 0
    if days == 0 { return "Hoje" }
    if days == 1 { return "Ontem" }
    return self.date(milliseconds, format: days > 1 && days < 7 ? "EEEE" : "dd/MM/yyyy")
  }
  public static func sticky(_ messages: [ConversationMessage], before visibleID: String?)
    -> ConversationMessage?
  {
    guard let index = messages.firstIndex(where: { $0.id == visibleID }) else { return nil }
    return messages[...index].last { $0.type == "user" }
  }
  public static func unread(_ messages: [ConversationMessage], viewed: Double?) -> String? {
    guard let viewed else { return nil }
    return messages.first {
      $0.type == "assistant" && ($0.time.completed ?? $0.time.created) > viewed
    }?.id
  }
  public static func viewedWatermark(
    idle: Double?, viewed: Double?, acknowledged: Double?, visible: Bool
  ) -> Double? {
    guard visible, let idle, idle > max(viewed ?? 0, acknowledged ?? 0) else { return nil }
    return idle
  }
  public static func runningCount(
    ownerID: String, viewedID: String, messages: [ConversationMessage], children: [Session],
    active: Set<String>, shells: [ShellInfo]
  ) -> Int {
    runningWork(
      ownerID: ownerID, viewedID: viewedID, messages: messages, children: children,
      active: active, shells: shells
    ).count
  }
  public static func workStarted(child: Session, shells: [ShellInfo]) -> Double {
    shells.filter { $0.status == "running" && $0.metadata?["sessionID"]?.string == child.id }
      .map(\.time.started).min() ?? child.time.updated
  }
  public static func ellipsis(_ text: String, count: Int) -> String {
    String(text.prefix(count)).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?… \n\r\t"))
      + "…"
  }
  public static func merge(
    _ existing: [ConversationMessage], page: [ConversationMessage], older: Bool = false
  ) -> [ConversationMessage] {
    let replacements = Dictionary(page.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let ids = Set(existing.map(\.id))
    let additions = page.filter { !ids.contains($0.id) }
    let updated = existing.map { replacements[$0.id] ?? $0 }
    return older ? additions + updated : updated + additions
  }
}
