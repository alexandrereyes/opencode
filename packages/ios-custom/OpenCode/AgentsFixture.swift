#if DEBUG && os(iOS)
import Foundation
import OpenCodeKit
import Synchronization

/// `-OpenCodeAgentsFixture <subagents>`: a large live family, served in memory through the app's real client, stores
/// and event path (no server, no model), to measure "Agentes e tarefas". The root has `<subagents>` children: the
/// first `-OpenCodeAgentsFixtureActive` (5) run and grow their context, cost and Progresso; the next one keeps three
/// background shells, and the one after has a child in another worktree with one; the rest finished. Events for the
/// running children arrive like a live server's (`-OpenCodeAgentsFixtureEvents <per second>`, 0 for none): deltas,
/// and every fourth a step event, which makes the conversation and Sessões reload. After 12 s one running child
/// finishes, after 15 s the background shells end. `-OpenCodeOpenAgents` opens the screen over the root.
enum AgentsFixture {
  static let count: Int? = argument("-OpenCodeAgentsFixture").flatMap(Int.init)
  static var enabled: Bool { count != nil }
  static let running = argument("-OpenCodeAgentsFixtureActive").flatMap(Int.init) ?? 5
  static let rate = argument("-OpenCodeAgentsFixtureEvents").flatMap(Double.init) ?? 20
  /// Diagnostics only: the running titles without their shimmer, the metrics without their 1-s clock.
  static let noShimmer = ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureNoShimmer")
  static let noClock = ProcessInfo.processInfo.arguments.contains("-OpenCodeFixtureNoClock")
  /// `+N concluídos` open when the screen appears.
  static let expanded = ProcessInfo.processInfo.arguments.contains("-OpenCodeAgentsFixtureExpanded")
  static let rootID = "ses_agents_root"
  static let directory = "/Projetos/refactor"

  private static func argument(_ name: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  static func client(_ configuration: ServerConfiguration) -> OpenCodeClient {
    let server = Server(count: count ?? 244)
    return .inMemory(configuration: configuration) { request in server.respond(request) }
  }

  /// The live server's events for the running children, through the hub every screen listens to.
  @MainActor static func stream(_ hub: EventHub) async {
    guard rate > 0, let count else { return }
    var tick = 0
    while !Task.isCancelled {
      do { try await Task.sleep(for: .milliseconds(Int(1000 / rate))) } catch { return }
      let child = Server.childID(tick % max(1, min(running, count)))
      let type = tick % 4 == 3 ? "session.step.ended" : "session.text.delta"
      let event = #"{"type":"\#(type)","data":{"sessionID":"\#(child)","id":"prt_\#(child)","delta":"pensando "}}"#
      if let decoded = try? JSONDecoder().decode(ConversationEvent.self, from: Data(event.utf8)) {
        hub.inject(.update(decoded))
      }
      tick += 1
    }
  }

  final class Server: Sendable {
    let count: Int
    private let started = Date.now.timeIntervalSince1970 * 1000
    private let unknown = Mutex<Set<String>>([])
    init(count: Int) { self.count = count }

    static func childID(_ index: Int) -> String { String(format: "ses_agents_c%04d", index) }
    private static let titles = ["Juiz B: sobra", "Juiz B: pos-resposta", "Juiz B: acao", "llm-proxy: testar /v1/decisions",
      "Revisar o contrato do plugin", "Medir a lista de Sessões", "Mapear os testes do Mac", "Ajustar a Live Activity"]
    private static let agents = ["opushigh", "solxhigh", "terrahigh", "explore"]

    private var now: Double { Date.now.timeIntervalSince1970 * 1000 }
    private var elapsed: Double { now - started }
    private var finishedOne: Bool { elapsed > 12_000 }
    private var shellsEnded: Bool { elapsed > 15_000 }
    private var live: [Int] { Array(0..<min(running, count)).filter { !(finishedOne && $0 == 0) } }

    func respond(_ request: URLRequest) -> String? {
      guard let url = request.url else { return nil }
      let path = url.path
      let input = request.httpBody.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }?["input"]?.object
      switch path {
      case "/api/info": return #"{"version":"0.0.0-agents-fixture","paths":{"tmp":"/tmp"}}"#
      case "/api/session/active":
        return #"{"data":{"# + live.map { #""\#(Self.childID($0))":{"type":"running"}"# }.joined(separator: ",") + "}}"
      case "/api/session/\(AgentsFixture.rootID)": return #"{"data":\#(root)}"#
      case "/api/session/\(AgentsFixture.rootID)/inbox": return #"{"data":[]}"#
      case "/api/model":
        return #"{"data":[{"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","variants":[{"id":"high"}],"limit":{"context":1000000}},{"id":"sol-6.1","providerID":"llm-proxy","name":"Sol 6.1","variants":[{"id":"xhigh"}],"limit":{"context":400000}}]}"#
      case "/api/model/default": return #"{"data":{"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","limit":{"context":1000000}}}"#
      case "/api/agent":
        return #"{"data":["# + (["build"] + Self.agents).map {
          #"{"id":"\#($0)","name":"\#($0)","mode":"\#($0 == "build" ? "primary" : "subagent")"}"#
        }.joined(separator: ",") + "]}"
      case "/api/provider": return #"{"data":[{"id":"llm-proxy","name":"LLM proxy"}]}"#
      case "/api/shell": return #"{"data":[]}"#
      case "/api/config": return #"[{"type":"document","info":{"default_agent":"build","experimental":{"todo":true}}}]"#
      case "/api/project", "/api/worktree": return "[]"
      case "/api/session": return #"{"data":[],"cursor":{}}"#
      case "/api/form": return #"{"data":[]}"#
      case "/api/mcp": return #"{"data":[]}"#
      case "/api/rpc/custom.preferences/get":
        return #"{"output":{"revision":1,"data":{"projects":{},"pinnedSessions":[],"settings":{"autoApprove":false}}}}"#
      case "/api/rpc/custom.navigation/list": return #"{"output":{"data":[\#(navigation)]}}"#
      case "/api/rpc/custom.session-family/snapshot": return #"{"output":\#(snapshot)}"#
      case "/api/rpc/custom.session-family/page":
        let after = input?["after"]?.string.flatMap { id in (0..<count).first { Self.childID($0) == id } }
        let start = after.map { $0 + 1 } ?? 0
        let end = min(count, start + 100)
        let next = end < count ? #","next":"\#(Self.childID(end - 1))""# : ""
        return #"{"output":{"data":[\#((start..<end).map(child).joined(separator: ","))]\#(next)}}"#
      case "/api/rpc/custom.transcript/list":
        let id = input?["sessionID"]?.string ?? ""
        return id == AgentsFixture.rootID ? #"{"output":{"data":[\#(transcript)],"cursor":{}}}"# : tail(id)
      case "/api/rpc/custom.worktrees/available": return #"{"output":true}"#
      case "/api/rpc/custom.worktrees/locate":
        return #"{"output":[{"directory":"\#(AgentsFixture.directory)","worktree":"\#(AgentsFixture.directory)","canonical":"\#(AgentsFixture.directory)","branch":"refactor-gpt-live"}]}"#
      case "/api/rpc/custom.requests/permissions": return #"{"output":[]}"#
      case "/api/rpc/custom.chats/info": return #"{"output":{"root":"/Chats"}}"#
      case "/api/rpc/custom.resources/list": return #"{"output":[]}"#
      default:
        if unknown.withLock({ $0.insert(path).inserted }) { print("AgentsFixture: sem resposta para \(path)") }
        return nil
      }
    }

    private var root: String {
      #"{"id":"\#(AgentsFixture.rootID)","projectID":"project_refactor","title":"Refactor GPT Live","agent":"build","model":{"id":"opus-5.5","providerID":"llm-proxy","variant":"high"},"cost":42.5,"location":{"directory":"\#(AgentsFixture.directory)"},"outcome":"succeeded","time":{"created":\#(started - 7_200_000),"updated":\#(started - 600_000),"idle":\#(started - 600_000),"viewed":\#(started - 600_000)}}"#
    }

    /// A child as `custom.session-family/page` and `custom.navigation/list` return it; the running ones grow.
    private func child(_ index: Int) -> String {
      let running = live.contains(index)
      let finishedNow = finishedOne && index == 0
      let created = started - Double(index + 1) * 45_000
      let updated = running ? now : finishedNow ? started + 12_000 : started - Double(index) * 30_000
      let input = running ? 20_000 + Int(elapsed / 10) + index * 1_000 : 40_000 + index * 37
      let model = index % 5 == 4 ? #"{"id":"sol-6.1","providerID":"llm-proxy","variant":"xhigh"}"#
        : #"{"id":"opus-5.5","providerID":"llm-proxy","variant":"high"}"#
      let outcome = running ? "" : #","outcome":"\#(index % 23 == 7 ? "failed" : "succeeded")""#
      let idle = running ? "" : #","idle":\#(updated)"#
      let tokens = #"{"input":\#(input),"output":\#(input / 20),"reasoning":0,"cache":{"read":\#(input * 4),"write":0}}"#
      return #"{"id":"\#(Self.childID(index))","parentID":"\#(AgentsFixture.rootID)","projectID":"project_refactor","title":"\#(Self.titles[index % Self.titles.count]) \#(index)","agent":"\#(Self.agents[index % Self.agents.count])","model":\#(model),"cost":\#(Double(input) / 100_000),"tokens":\#(tokens),"context":{"id":"msg_ctx_\#(index)","tokens":\#(tokens),"model":\#(model)},"location":{"directory":"\#(AgentsFixture.directory)"}\#(outcome),"time":{"created":\#(created),"updated":\#(updated)\#(idle)}}"#
    }

    /// Every Sessões row: the root, its family (a grandchild in another worktree) and other roots, about the 526 rows
    /// of the server this fixture copies the shape of.
    private var navigation: String {
      let background = min(running, count)
      var rows = [#"{"session":\#(root)}"#]
      rows += (0..<count).map { index in
        let shells = index == background && !shellsEnded
          ? #","backgroundCount":3,"backgroundTitle":"python3 servico.py core""# : ""
        return #"{"session":\#(child(index))\#(shells)}"#
      }
      if count > background + 1 {
        let grandchild = #"{"id":"ses_agents_g0001","parentID":"\#(Self.childID(background + 1))","projectID":"project_other","title":"Neto noutra worktree","location":{"directory":"/Projetos/refactor-other"},"outcome":"succeeded","time":{"created":\#(started - 90_000),"updated":\#(started - 60_000),"idle":\#(started - 60_000)}}"#
        rows.append(#"{"session":\#(grandchild),"backgroundCount":1,"backgroundTitle":"sleep 600"}"#)
      }
      rows += (0..<max(20, 526 - rows.count)).map { index in
        let time = started - Double(index + 1) * 3_600_000
        return #"{"session":{"id":"ses_agents_other_\#(index)","projectID":"project_other_\#(index % 12)","title":"Outra sessão \#(index)","location":{"directory":"/Projetos/outro-\#(index % 12)"},"outcome":"succeeded","time":{"created":\#(time),"updated":\#(time),"idle":\#(time),"viewed":\#(time)}}}"#
      }
      return rows.joined(separator: ",")
    }

    private var snapshot: String {
      let active = live.map(child).joined(separator: ",")
      let todos = #"[{"content":"Ler o contrato","status":"completed"},{"content":"Executar a suíte inteira, classificar falhas e relatar placar e tempos","status":"in_progress"},{"content":"Escrever o resumo","status":"pending"}]"#
      let progress = live.contains(min(4, count - 1))
        ? #","progress":{"\#(Self.childID(min(4, count - 1)))":{"done":2,"finished":2,"total":3,"current":"Executar a suíte inteira, classificar falhas e relatar placar e tempos","todos":\#(todos)}}"#
        : ""
      return #"{"count":\#(count),"cost":\#(Double(count) * 0.21),"active":[\#(active)],"forms":[],"permissions":[]\#(progress)}"#
    }

    /// The root's newest page: 40 messages with a subagent call for each of the newest children, like the copied
    /// family's tail (about one call in three messages).
    private var transcript: String {
      (0..<40).map { index in
        let created = started - Double(40 - index) * 60_000
        guard index % 3 == 0, index / 3 < count else {
          return #"{"id":"msg_agents_\#(index)","type":"user","time":{"created":\#(created)},"text":"Continue o refactor \#(index)."}"#
        }
        let child = Self.childID(index / 3)
        return #"{"id":"msg_agents_\#(index)","type":"assistant","agent":"build","model":{"id":"opus-5.5","providerID":"llm-proxy","variant":"high"},"time":{"created":\#(created),"completed":\#(created + 1000)},"finish":"stop","content":[{"type":"text","text":"Delegando."},{"type":"tool","id":"call_agents_\#(index)","name":"subagent","time":{"created":\#(created),"ran":\#(created)},"state":{"status":"completed","input":{"agent":"opushigh","description":"\#(Self.titles[(index / 3) % Self.titles.count]) \#(index / 3)","prompt":"…"},"metadata":{"sessionID":"\#(child)"},"content":[{"type":"text","text":"ok"}]}}]}"#
      }.reversed().joined(separator: ",")
    }

    /// A running child's transcript tail (`client.preview`): its current tool, for `agora: …`.
    private func tail(_ id: String) -> String {
      let created = now - 5_000
      return #"{"output":{"data":[{"id":"msg_tail_\#(id)","type":"assistant","agent":"opushigh","time":{"created":\#(created)},"content":[{"type":"tool","id":"call_tail_\#(id)","name":"bash","time":{"created":\#(created),"ran":\#(created)},"state":{"status":"running","input":{"command":"bun test","description":"Rodar os testes"}}}]}],"cursor":{}}}"#
    }
  }
}
#endif
