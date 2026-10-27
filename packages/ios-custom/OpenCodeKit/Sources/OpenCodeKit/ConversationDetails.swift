import Foundation

/// A subagent or background shell of the conversation's owner, running or finished.
public struct SessionWork: Identifiable, Sendable, Equatable {
  /// Agents are subagent sessions, in the foreground or background; scripts are background shells.
  public enum Kind: Sendable, Equatable { case agent, script }
  public enum State: Sendable, Equatable {
    case starting, running, completed, failed, interrupted, ended
    public var label: String {
      switch self {
      case .starting: "Iniciando"
      case .running: "Em execução"
      case .completed: "Concluído"
      case .failed: "Erro"
      case .interrupted: "Interrompido"
      case .ended: "Encerrado"
      }
    }
  }
  public let id: String
  public let kind: Kind
  public let sessionID: String?
  public let shellID: String?
  public let toolID: String?
  public let agent: String?
  public let title: String
  public let state: State
  /// The most recent activity: the latest start while running, otherwise the last time it ran. Running work
  /// comes first and each group is ordered by this, newest first.
  public let activity: Double
  /// The running elapsed-time origin: the current busy period of a resumed child.
  public let started: Double
  /// Total duration of finished work, when known.
  public let duration: Double?
  public var running: Bool { state == .running }
  /// Running or about to run: listed before finished work.
  public var live: Bool { state == .running || state == .starting }
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
    let latest = ConversationProjection.latestMeasurement(messages)
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
  /// Every subagent of the owner and every background shell it started. Running (or starting) work comes
  /// first, then finished work, each by most recent activity. Agents and scripts never mix: a shell is never an
  /// agent placeholder.
  public static func work(
    ownerID: String, viewedID: String, messages: [ConversationMessage], children: [Session],
    active: Set<String>, shells: [ShellInfo]
  ) -> [SessionWork] {
    let tools = messages.flatMap(\.tools)
    return (agents(ownerID: ownerID, viewedID: viewedID, tools: tools, children: children, active: active, shells: shells)
      + scripts(ownerID: ownerID, tools: tools, shells: shells))
      .sorted {
        if $0.live != $1.live { return $0.live }
        return $0.activity != $1.activity ? $0.activity > $1.activity : $0.id < $1.id
      }
  }

  private static func agents(
    ownerID: String, viewedID: String, tools: [ConversationPart], children: [Session], active: Set<String>,
    shells: [ShellInfo]
  ) -> [SessionWork] {
    let links = subagentLinks(tools: tools, children: children, ownerID: ownerID)
    var work: [SessionWork] = children.filter { $0.parentID == ownerID && $0.id != viewedID }.map { child in
      let linked = tools.filter { $0.name == "subagent" && $0.id.flatMap { links[$0] } == child.id }
      let tool = linked.first
      // A continued child is started again by its latest call; a background call completes at once.
      let latest = linked.last.flatMap { $0.time?.ran ?? $0.time?.created }
      let state = active.contains(child.id) ? .running : finishedState(child.outcome, tool: linked.last?.status)
      let ended = child.time.idle ?? child.time.updated
      return SessionWork(
        id: child.id, kind: .agent, sessionID: child.id, shellID: nil, toolID: tool?.id,
        agent: tool?.input["agent"]?.string ?? child.agent,
        title: tool?.input["description"]?.string ?? child.displayTitle, state: state,
        activity: state == .running ? max(latest ?? child.time.created, child.time.created) : ended,
        started: latest ?? workStarted(child: child, shells: shells),
        duration: state == .running ? nil : ended - child.time.created)
    }
    // A call whose child does not exist yet is only shown while the owner is still running it; it has
    // nothing to open. Stale running parts and failures without a child stay in the transcript only.
    guard active.contains(ownerID) else { return work }
    for tool in tools where tool.name == "subagent" && tool.running {
      guard let id = tool.id, links[id] == nil else { continue }
      let created = tool.time?.ran ?? tool.time?.created ?? 0
      // While the model still writes the call, its input is partial JSON: read the fields already complete.
      work.append(
        SessionWork(
          id: id, kind: .agent, sessionID: nil, shellID: nil, toolID: nil,
          agent: tool.input["agent"]?.string ?? tool.partialInput("agent"),
          title: tool.input["description"]?.string ?? tool.partialInput("description") ?? "Preparando subagente…",
          state: .starting, activity: created, started: created, duration: nil))
    }
    return work
  }

  /// Background shells: those a completed `shell` call moved to the background (its result says `running`),
  /// plus any running shell of the owner that no foreground call is waiting on.
  private static func scripts(ownerID: String, tools: [ConversationPart], shells: [ShellInfo]) -> [SessionWork] {
    let info = Dictionary(shells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let calls = tools.filter {
      $0.name == "shell" && $0.status == "completed" && $0.metadata["status"]?.string == "running"
        && $0.metadata["shellID"]?.string != nil
    }
    var work: [SessionWork] = calls.map { call in
      let id = call.metadata["shellID"]!.string!
      let shell = info[id]
      let created = shell?.time.started ?? call.time?.ran ?? call.time?.created ?? 0
      let state = shell.map(shellState) ?? .ended
      return SessionWork(
        id: id, kind: .script, sessionID: nil, shellID: id, toolID: call.id,
        agent: nil, title: call.input["command"]?.string ?? shell?.command ?? id, state: state,
        activity: state == .running ? created : shell?.time.completed ?? created,
        started: created, duration: state == .running ? nil : shell?.time.completed.map { $0 - created })
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
    let listed = Set(work.map(\.id))
    work += shells.filter {
      $0.status == "running" && $0.metadata?["sessionID"]?.string == ownerID
        && !foreground.contains($0.id) && !listed.contains($0.id)
    }.map { shell in
      SessionWork(
        id: shell.id, kind: .script, sessionID: nil, shellID: shell.id,
        toolID: tools.first { $0.metadata["shellID"]?.string == shell.id || $0.id == shell.id }?.id,
        agent: nil, title: shell.command, state: .running, activity: shell.time.started,
        started: shell.time.started, duration: nil)
    }
    return work
  }

  private static func shellState(_ shell: ShellInfo) -> SessionWork.State {
    switch shell.status {
    case "running": .running
    case "exited": shell.exit.map { $0 == 0 } == false ? .failed : .completed
    case "timeout": .failed
    case "killed": .interrupted
    default: .ended
    }
  }

  /// Links each `subagent` call to its child session. The child's ID reaches the part only through
  /// ephemeral progress and the final result, so a reloaded running call has no `sessionID`: a
  /// continuation names it in its input, and a new call is matched to the first unclaimed child of the
  /// owner created right after the call began, with the same agent.
  public static func subagentLinks(tools: [ConversationPart], children: [Session], ownerID: String)
    -> [String: String]
  {
    let calls = tools.filter { $0.name == "subagent" && $0.id != nil }
    var links: [String: String] = [:]
    for call in calls {
      if let child = call.childID ?? call.input["sessionID"]?.string { links[call.id!] = child }
    }
    var claimed = Set(links.values)
    let candidates = children.filter { $0.parentID == ownerID }.sorted { $0.time.created < $1.time.created }
    for call in calls where links[call.id!] == nil {
      guard let start = call.time?.ran ?? call.time?.created else { continue }
      let agent = call.input["agent"]?.string
      guard
        let child = candidates.first(where: {
          !claimed.contains($0.id) && $0.time.created >= start - 5_000 && $0.time.created <= start + 60_000
            && (agent == nil || $0.agent == nil || $0.agent == agent)
        })
      else { continue }
      links[call.id!] = child.id
      claimed.insert(child.id)
    }
    return links
  }

  private static func finishedState(_ outcome: Session.Outcome?, tool: String?) -> SessionWork.State {
    switch outcome {
    case .succeeded: .completed
    case .failed: .failed
    case .interrupted: .interrupted
    case .unknown, nil: tool == "error" ? .failed : tool == "completed" ? .completed : .ended
    }
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
