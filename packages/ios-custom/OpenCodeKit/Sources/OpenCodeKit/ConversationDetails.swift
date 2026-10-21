import Foundation

public struct RunningWork: Identifiable, Sendable {
  public let id: String
  public let sessionID: String?
  public let shellID: String?
  public let toolID: String?
  public let agent: String?
  public let title: String
  public let started: Double
}

public struct ContextDetails: Sendable {
  public let tokens: TokenUsage?
  public let model: ModelInfo?
  public let reference: ModelReference?
  public let sessionCost: Double?
  public let familyCost: Double?
  public var total: Double? { tokens?.total }
  public var fraction: Double? {
    guard let total, let limit = model?.limit.context, limit > 0 else { return nil }
    return total / limit
  }
  public var cacheHit: Double? {
    guard let tokens else { return nil }
    let denominator = tokens.input + tokens.cache.read + tokens.cache.write
    return denominator > 0 ? tokens.cache.read / denominator : nil
  }
  public var totalCost: Double? { sessionCost.map { $0 + (familyCost ?? 0) } }
  public init(
    messages: [ConversationMessage], models: [ModelInfo], session: Session?, family: FamilySnapshot?
  ) {
    let latest = messages.last { $0.type == .assistant && $0.tokens != nil }
    tokens = latest?.tokens
    reference = latest?.model
    model = models.first {
      $0.id == latest?.model?.id && $0.providerID == latest?.model?.providerID
    }
    sessionCost = session?.cost
    familyCost = family?.cost
  }
}

extension ConversationProjection {
  public static func runningWork(
    ownerID: String, viewedID: String, messages: [ConversationMessage], children: [Session],
    active: Set<String>, shells: [ShellInfo]
  ) -> [RunningWork] {
    let tools = messages.flatMap(\.tools)
    var work: [RunningWork] = children.filter {
      $0.parentID == ownerID && $0.id != viewedID && active.contains($0.id)
    }.map { child in
      let tool = tools.first { $0.name == "subagent" && $0.childID == child.id }
      return RunningWork(
        id: child.id, sessionID: child.id, shellID: nil, toolID: tool?.id,
        agent: tool?.input["agent"]?.string ?? child.agent,
        title: tool?.input["description"]?.string ?? child.displayTitle,
        started: workStarted(child: child, shells: shells))
    }
    for tool in tools where tool.name == "subagent" && tool.running {
      let id = tool.childID ?? tool.id ?? "starting"
      guard id != viewedID, !work.contains(where: { $0.id == id }) else { continue }
      work.append(
        RunningWork(
          id: id, sessionID: tool.childID, shellID: nil, toolID: tool.id,
          agent: tool.input["agent"]?.string,
          title: tool.input["description"]?.string ?? "Iniciando agente…",
          started: tool.time?.ran ?? tool.time?.created ?? 0))
    }
    var foreground = Set(
      tools.filter { $0.name == "shell" && $0.running }.compactMap {
        $0.metadata["shellID"]?.string
      })
    for tool in tools where tool.name == "shell" && tool.running && tool.metadata["shellID"] == nil
    {
      let candidate = shells.filter {
        $0.metadata?["sessionID"]?.string == ownerID && $0.command == tool.input["command"]?.string
          && !foreground.contains($0.id)
      }.min {
        abs($0.time.started - (tool.time?.ran ?? tool.time?.created ?? 0))
          < abs($1.time.started - (tool.time?.ran ?? tool.time?.created ?? 0))
      }
      if let candidate { foreground.insert(candidate.id) }
    }
    work += shells.filter {
      $0.status == "running" && $0.metadata?["sessionID"]?.string == ownerID
        && !foreground.contains($0.id)
    }.map { shell in
      RunningWork(
        id: shell.id, sessionID: nil, shellID: shell.id,
        toolID: tools.first { $0.metadata["shellID"]?.string == shell.id || $0.id == shell.id }?.id,
        agent: nil, title: shell.command, started: shell.time.started)
    }
    return work
  }

  public static func pendingTool(
    _ part: ConversationPart, permissions: [PermissionRequest], forms: [PendingForm]
  ) -> String? {
    if let permission = permissions.first(where: {
      $0.source?.type == "tool" && $0.source?.id == part.id
    }) {
      return
        "Aguardando permissão · \(permission.resources.first ?? part.input["command"]?.string ?? permission.action)"
    }
    if let form = forms.first(where: { $0.metadata?["tool"]?.object?["id"]?.string == part.id }) {
      return "Aguardando resposta · \(form.fields.first?.title ?? form.title)"
    }
    return nil
  }

  public static func visibleModels(_ models: [ModelInfo], preferences: Preferences.Models?)
    -> [ModelInfo]
  {
    models.filter { model in
      model.enabled != false
        && preferences?.user.last {
          $0.providerID == model.providerID && $0.modelID == model.id
        }?.visibility == "show"
    }
  }
  public static func favorite(_ model: ModelInfo, preferences: Preferences.Models?) -> Bool {
    if let favorites = preferences?.favorites {
      return favorites.contains { $0.providerID == model.providerID && $0.modelID == model.id }
    }
    return preferences?.user.contains {
      $0.providerID == model.providerID && $0.modelID == model.id && $0.favorite == true
    } == true
  }
  public static func normalizeModelSearch(_ text: String) -> String {
    text.lowercased().replacingOccurrences(
      of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression
    )
    .trimmingCharacters(in: .whitespaces)
  }
  public static func matchesModel(_ model: ModelInfo, query: String, providerName: String? = nil)
    -> Bool
  {
    matchesModelSearch(query, values: [model.name, model.id, providerName ?? model.providerID])
  }
  public static func matchesModelSearch(_ query: String, values: [String]) -> Bool {
    let query = normalizeModelSearch(query)
    if query.isEmpty { return true }
    return values.contains {
      let text = normalizeModelSearch($0)
      return text.contains(query)
        || text.replacingOccurrences(of: " ", with: "").contains(
          query.replacingOccurrences(of: " ", with: ""))
    }
  }
  public static func modelProviders(
    _ models: [ModelInfo], providers: [ProviderInfo], order: [String]
  ) -> [ProviderInfo] {
    let popular = [
      "opencode-go", "opencode", "anthropic", "github-copilot", "openai", "google", "openrouter",
      "vercel",
    ]
    return Set(models.map(\.providerID)).map { id in
      providers.first { $0.id == id } ?? ProviderInfo(id: id, name: id)
    }.sorted { a, b in
      let first = order.firstIndex(of: a.id) ?? Int.max
      let second = order.firstIndex(of: b.id) ?? Int.max
      if first != second { return first < second }
      let firstPopular = popular.firstIndex(of: a.id) ?? Int.max
      let secondPopular = popular.firstIndex(of: b.id) ?? Int.max
      if firstPopular != secondPopular { return firstPopular < secondPopular }
      return a.name.localizedCompare(b.name) == .orderedAscending
    }
  }
}
