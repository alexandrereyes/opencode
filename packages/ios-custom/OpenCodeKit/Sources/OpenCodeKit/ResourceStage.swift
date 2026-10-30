import Foundation

/// The Mac's Recursos as a stage (approved option B, 30/10): one ligado resource large with its live video, the other
/// ligados as small thumbnails, the stopped ones as chips. "Seguir o agente" puts on the stage the resource an agent is
/// using now; choosing one by hand turns it off until Alexandre turns it back on.
public enum ResourceStage {
  /// Ligados: every resource neither stopped nor gone, in use now first (Alexandre's control, then the agents'), then
  /// ao vivo, then livre; each by latest use.
  public static func on(_ resources: [SessionResource]) -> [SessionResource] {
    resources.filter(\.state.running).sorted { a, b in
      if rank(a) != rank(b) { return rank(a) < rank(b) }
      return a.lastUsedAt != b.lastUsedAt ? a.lastUsedAt > b.lastUsedAt : a.id < b.id
    }
  }

  /// Parados: stopped and gone, most recently seen first.
  public static func off(_ resources: [SessionResource]) -> [SessionResource] {
    resources.filter { !$0.state.running }.sorted { a, b in
      seen(a) != seen(b) ? seen(a) > seen(b) : a.id < b.id
    }
  }

  /// The resource an agent is using now: one whose command is still running, else the most recently used. Nil while
  /// no agent uses any.
  public static func inUse(_ on: [SessionResource]) -> SessionResource? {
    let agents = on.filter { $0.state == .agent }
    return agents.first { $0.activity?.contains { $0.running == true } == true } ?? agents.first
  }

  /// What the stage shows. A resource Alexandre controls from the stage stays there whatever happens; following, the
  /// agent's resource takes it, else the current one stays; by hand, the chosen one stays while it is on. Whatever
  /// goes off, the first ligado replaces it.
  public static func pick(
    _ on: [SessionResource], following: Bool, chosen: String?, current: String?, controlling: Bool
  ) -> String? {
    let ids = Set(on.map(\.id))
    if controlling, let current, ids.contains(current) { return current }
    if following, let used = inUse(on) { return used.id }
    if !following, let chosen, ids.contains(chosen) { return chosen }
    if let current, ids.contains(current) { return current }
    return on.first?.id
  }

  /// The stage and the thumbnails beside it, in order.
  public static func split(_ on: [SessionResource], stage: String?) -> (stage: SessionResource?, others: [SessionResource]) {
    let shown = on.first { $0.id == stage }
    return (shown, on.filter { $0.id != shown?.id })
  }

  /// The first `limit` stopped resources as chips, and how many more `+N ›` opens.
  public static func chips(_ off: [SessionResource], limit: Int, all: Bool) -> (shown: [SessionResource], more: Int) {
    all || off.count <= limit ? (off, 0) : (Array(off.prefix(limit)), off.count - limit)
  }

  /// `iPhone 17 Pro · 2 min`: the resource's own name and how long it has been stopped.
  public static func chip(_ resource: SessionResource, now: Date = .now) -> String {
    ContextColumn.name(resource) + " · " + span(seen(resource), now: now)
  }

  /// The stage's state line: `Você no controle`, `Agente usando · App Mac — Backend da Live Activity` (the shown
  /// session, then the subagent that used it), `Ao vivo · usado há 3 min`, `Livre`.
  public static func status(_ resource: SessionResource, session: String?, subagent: String?, now: Date = .now) -> String {
    switch resource.state {
    case .agent:
      let who = [session, subagent].compactMap { $0 }.joined(separator: " — ")
      return who.isEmpty ? resource.state.label : resource.state.label + " · " + who
    case .live: return resource.state.label + " · usado " + ago(resource.lastUsedAt, now: now)
    default: return resource.state.label
    }
  }

  /// `agora: agent-device test flows/gravar.yaml` for a command still running, then the latest ones as
  /// `há 20 s: agent-device fill "Nome"`, at most `limit` lines.
  public static func history(_ resource: SessionResource, now: Date = .now, limit: Int = 3) -> [String] {
    (resource.activity ?? []).prefix(limit).map { item in
      (item.running == true ? "agora" : ago(item.at, now: now)) + ": " + item.command
    }
  }

  /// "há 20 s", "há 3 min", "há 2 h", "há 3 d".
  public static func ago(_ milliseconds: Double, now: Date = .now) -> String {
    "há " + span(milliseconds, now: now)
  }

  private static func span(_ milliseconds: Double, now: Date) -> String {
    let seconds = max(0, Int((now.timeIntervalSince1970 * 1000 - milliseconds) / 1000))
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3_600 { return "\(seconds / 60) min" }
    if seconds < 86_400 { return "\(seconds / 3_600) h" }
    return "\(seconds / 86_400) d"
  }

  private static func rank(_ resource: SessionResource) -> Int {
    switch resource.state {
    case .user: 0
    case .agent: 1
    case .live: 2
    default: 3
    }
  }

  private static func seen(_ resource: SessionResource) -> Double {
    resource.updatedAt > 0 ? resource.updatedAt : resource.lastUsedAt
  }
}
