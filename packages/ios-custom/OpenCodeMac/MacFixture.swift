#if DEBUG
import AppKit
import OpenCodeKit

/// A closed, in-memory server for captures and offline checks (`-OpenCodeMacFixture contexto`). It answers the
/// same endpoints the app reads from a real server, with synthetic sessions, subagents, tasks, resources and
/// working-copy changes; folders and files come from this Mac's checkout (`-OpenCodeMacFixtureRoot <path>`), so
/// Arquivos lists real files. No request ever leaves the process.
@MainActor struct MacFixture {
  // The fragment is a persistence namespace, never a network destination. Parallel test app copies must not
  // share their synthetic root's drafts/reading state just because both use the closed in-memory server.
  static let configuration = ServerConfiguration(
    url: URL(string: (MacVoiceChecks.enabled ? "http://127.0.0.1:4203/#" : "http://127.0.0.1:9/#")
      + (Bundle.main.bundleIdentifier ?? "mac-fixture"))!)
  static let current: MacFixture? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("-OpenCodeMacFixture") else { return nil }
    let root = value("-OpenCodeMacFixtureRoot") ?? FileManager.default.currentDirectoryPath
    return MacFixture(root: root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root)
  }()

  nonisolated static func value(_ key: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  let root: String
  nonisolated static let rootID = "ses_mac_root"

  var selection: MacSelection {
    var selection = MacSelection(sessionID: Self.rootID)
    if let folder = Self.value("-OpenCodeMacFiles") {
      let path = folder.hasPrefix("/") ? folder : root + "/" + folder
      let file = Self.value("-OpenCodeMacFile").map { $0.hasPrefix("/") ? $0 : path + "/" + $0 }
      selection.files = MacSelection.Files(folder: path, file: file)
    }
    return selection
  }

  func client() -> OpenCodeClient {
    let server = MacFixtureServer(root: root, now: Date.now.timeIntervalSince1970 * 1000,
      pictures: MacFixturePictures.make())
    let proxy = MacFixtureProxy(now: .now)
    return .inMemory(configuration: Self.configuration, answer: { request in
      if MacChoicesFixture.enabled,
        let answer = await MacChoicesFixture.shared.respond(request, fallback: server.respond(request)) { return answer }
      let path = request.url?.path ?? ""
      guard path.hasPrefix("/api/rpc/custom.subscriptions/") else { return server.respond(request) }
      let input = request.httpBody.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }?["input"]?.object
      return await proxy.respond(String(path.dropFirst("/api/rpc/custom.subscriptions/".count)), input)
    })
  }
}

private struct MacFixtureServer: Sendable {
  let root: String
  let now: Double
  let pictures: [String: String]
  private let minute = 60_000.0
  private let home = "/Users/alexandremartins"
  /// `-OpenCodeMacFixtureAttention`: one root asking permission, one asking a question and one failed, for the
  /// "Precisa de você" section, the Dock badge and the alerts.
  private let attention = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacFixtureAttention")
  private let searchFixture = ProcessInfo.processInfo.arguments.contains("-OpenCodeMacSearchFixture")

  func respond(_ request: URLRequest) -> String? {
    guard let url = request.url else { return nil }
    let path = url.path
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let input = request.httpBody.flatMap { try? JSONDecoder().decode(RPC.self, from: $0) }?.input
    if path.hasPrefix("/api/rpc/") { return rpc(String(path.dropFirst("/api/rpc/".count)), input) }
    switch path {
    case "/api/info": return #"{"version":"0.0.0-mac-fixture","paths":{"tmp":"/tmp"}}"#
    case "/api/project": return projects
    case "/api/session/active":
      return #"{"data":{"#
        + (["ses_mac_root", "ses_mac_live"] + Self.live.map(\.id)).map { #""\#($0)":{"type":"running"}"# }
          .joined(separator: ",") + "}}"
    case "/api/session": return #"{"data":[\#(searchFixture ? archivedSession : "")],"cursor":{}}"#
    case "/api/model" where MacFixture.value("-OpenCodeMacLargeCatalog") != nil: return largeCatalog
    case "/api/provider" where MacFixture.value("-OpenCodeMacLargeCatalog") != nil:
      return #"{"data":[{"id":"llm-proxy","name":"LLM proxy"},{"id":"vercel","name":"Vercel AI Gateway"},{"id":"personal","name":"Personal / OpenCode"}]}"#
    case "/api/model": return #"{"data":[{"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","variants":[{"id":"high"},{"id":"xhigh"}],"limit":{"context":1000000}},{"id":"gpt-6-luna","providerID":"llm-proxy","name":"Luna 6","variants":[{"id":"low"},{"id":"medium"}],"limit":{"context":400000}},{"id":"sol-6.1","providerID":"llm-proxy","name":"Sol 6.1","limit":{"context":400000}}]}"#
    case "/api/agent":
      return #"{"data":["# + ["build", "explore", "opushigh", "terraxhigh", "terrahigh"].map {
        #"{"id":"\#($0)","name":"\#($0)","mode":"\#($0 == "build" ? "primary" : "subagent")"}"#
      }.joined(separator: ",") + "]}"
    case "/api/shell":
      return #"{"data":[{"id":"shl_dev","status":"running","command":"bun run dev --port 4177","metadata":{"sessionID":"ses_mac_root"},"time":{"started":\#(now - 12 * minute)}},{"id":"shl_test","status":"running","command":"xcodebuild test -scheme OpenCode","metadata":{"sessionID":"ses_mac_root"},"time":{"started":\#(now - 3 * minute)}}]}"#
    case "/api/vcs/diff": return "{\"data\":\(changes)}"
    // The composer's suggestions (`/` commands, `$` skills, `@` references, `#` snippets).
    case "/api/command":
      return #"{"data":[{"name":"review","description":"Revisar as mudanças"},{"name":"commit","description":"Analisa as mudanças e faz o commit"}]}"#
    case "/api/skill": return #"{"data":[{"id":"playwright-cli","name":"playwright-cli","description":"Automatiza o navegador"}]}"#
    case "/api/reference": return #"{"data":[]}"#
    case "/api/model/default": return #"{"data":{"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","variants":[{"id":"high"},{"id":"xhigh"}],"limit":{"context":1000000}}}"#
    // Nova sessão: the opencode2 project with two worktrees, its branches, configuration and MCPs.
    case "/api/vcs": return #"{"data":{"provider":"git","branch":{"current":"custom"}}}"#
    case "/api/vcs/branch": return #"{"data":["custom","mac-app","dev","upstream-dev","transcript-rewrite"]}"#
    case "/api/worktree":
      return #"[{"directory":"\#(home)/Worktrees/opencode2-mac-app"},{"directory":"\#(home)/Worktrees/opencode2-sidebar"}]"#
    case "/api/worktree/refresh": return "{}"
    case "/api/location": return #"{"directory":"\#(root)"}"#
    case "/api/provider": return #"{"data":[{"id":"llm-proxy","name":"LLM proxy"}]}"#
    case "/api/config": return #"[{"type":"document","info":{"default_agent":"build"}}]"#
    // Detalhes: the plugins of the directory.
    case "/api/plugin":
      return #"{"data":[{"name":"app-custom","state":{"status":"active"}},{"name":"opencode-notify","state":{"status":"disabled"}}]}"#
    case "/api/mcp":
      return #"{"data":[{"name":"chrome-devtools","status":{"status":"connected"}},{"name":"github","status":{"status":"disabled"}},{"name":"linear","status":{"status":"disabled"}},{"name":"sentry","status":{"status":"needs_auth"}}]}"#
    case "/api/session/\(MacFixture.rootID)/inbox":
      return #"{"data":[{"id":"inb_mac_1","sessionID":"\#(MacFixture.rootID)","type":"user","delivery":"queue","payload":{"text":"Depois roda os testes do Mac e do iPhone"},"time":{"created":\#(now - minute)}}]}"#
    case "/api/fs/list":
      return list(query.first { $0.name == "path" }?.value ?? query.first { $0.name == "location[directory]" }?.value ?? root)
    case "/api/fs/find": return find(query.first { $0.name == "query" }?.value ?? "")
    case "/api/form":
      return attention
        ? #"{"data":[{"id":"frm_mac_docs","sessionID":"ses_mac_docs","title":"Pergunta","fields":[{"key":"nome","type":"string","title":"Qual nome usar para o módulo de capturas?"}],"metadata":{"kind":"question"}}]}"#
        : #"{"data":[]}"#
    default:
      // A background task's output, read by cursor like the server's file-backed output.
      if path.hasPrefix("/api/shell/"), path.hasSuffix("/output") {
        let count = MacDetailsFixture.mode == "shell" ? max(1, Int(Date().timeIntervalSince1970 - now / 1000)) : 24
        let text = (1...count).map {
          MacDetailsFixture.mode == "shell" ? "[swift test] Teste \($0) concluído ✓" : "[vite] página recarregada · \($0 * 7) ms"
        }.joined(separator: "\n") + "\n"
        let data = Array(text.utf8)
        let cursor = min(Int(query.first { $0.name == "cursor" }?.value ?? "0") ?? 0, data.count)
        let chunk = String(decoding: data[cursor...], as: UTF8.self)
        let encoded = String(decoding: try! JSONEncoder().encode(chunk), as: UTF8.self)
        return #"{"data":{"output":\#(encoded),"cursor":\#(data.count),"size":\#(data.count),"truncated":false}}"#
      }
      if path.hasPrefix("/api/session/"), path.hasSuffix("/inbox") { return #"{"data":[]}"# }
      if path.hasPrefix("/api/session/"), path.hasSuffix("/view") {
        MacBellChecks.view(String(path.dropFirst("/api/session/".count).dropLast("/view".count)))
        return "{}"
      }
      // Pergunta paralela: a local Markdown answer, never a model.
      if path.hasPrefix("/api/session/"), path.hasSuffix("/generate") {
        return #"{"data":{"text":"Comece pelos **filtros de projetos**.\n\n1. Compare os caminhos mais usados.\n2. Faça uma mudança pequena em `MacChatColumn.swift`.\n3. Valide a navegação nos temas claro e escuro.\n\nA conversa principal continua no mesmo ponto."}}"#
      }
      if path.hasPrefix("/api/session/") {
        let id = String(path.dropFirst("/api/session/".count))
        return sessions[id].map { "{\"data\":\($0)}" }
      }
      return nil
    }
  }

  private func rpc(_ name: String, _ input: [String: JSONValue]?) -> String? {
    // `-OpenCodeMacResourceProfile`: one line per snapshot, to count the previews' refreshes.
    if name == "custom.resources/snapshot", MacFixture.value("-OpenCodeMacResourceProfile") != nil {
      print("MacResourceSnapshot \(input?["id"]?.string ?? "")")
      fflush(stdout)
    }
    let output: String? = switch name {
    case "custom.navigation/list": #"{"data":[\#(navigation)],"next":null}"#
    case "custom.preferences/get": preferences
    case "custom.requests/permissions":
      attention ? #"[{"id":"per_mac_sidebar","sessionID":"ses_mac_sidebar","action":"shell","resources":["git push --force-with-lease"]}]"# : "[]"
    case "custom.worktrees/available": "true"
    case "custom.snippets/list": #"{"items":[]}"#
    case "custom.chats/info": #"{"root":"\#(home)/Chats"}"#
    case "custom.master/info": #"{"version":1,"agent":"build","model":{"id":"opus-5.5","providerID":"llm-proxy"}}"#
    case "custom.directories/home": #"{"path":"\#(home)"}"#
    case "custom.worktrees/branches":
      #"[{"directory":"\#(home)/Dev/opencode2","branch":"custom"},{"directory":"\#(home)/Worktrees/opencode2-mac-app","branch":"mac-app"},{"directory":"\#(home)/Worktrees/opencode2-sidebar","branch":"sidebar-v2"}]"#
    case "custom.worktrees/locate":
      "[" + (input?["directories"]?.array?.compactMap(\.string) ?? []).map { directory in
        let branch = directory == root ? "mac-app" : "main"
        return #"{"directory":"\#(directory)","worktree":"\#(directory)","canonical":"\#(directory)","branch":"\#(branch)"}"#
      }.joined(separator: ",") + "]"
    case "custom.session-family/snapshot":
      input?["sessionID"]?.string == MacFixture.rootID
        ? #"{"count":\#(Self.children.count),"cost":63.89,"active":[\#(Self.live.map { session($0) }.joined(separator: ","))],"forms":[\#(rootQuestion)],"permissions":[\#(childPermission)]}"#
        : #"{"count":0,"active":[],"forms":[],"permissions":[]}"#
    case "custom.session-family/page":
      input?["sessionID"]?.string == MacFixture.rootID
        ? #"{"data":[\#(Self.children.map { session($0) }.joined(separator: ","))],"next":null}"#
        : #"{"data":[],"next":null}"#
    case "custom.transcript/list":
      transcript(input?["sessionID"]?.string ?? "", limit: input?["limit"]?.number.map(Int.init),
        cursor: input?["cursor"]?.string)
    case "custom.transcript/skills":
      #"{"data":[{"id":"opencode-custom","name":"opencode-custom"},{"id":"mac-prints","name":"Capturas do app de Mac"},{"id":"swift-testing","name":"Swift Testing"}]}"#
    case "custom.resources/list": #"{"resources":[\#(resources)]}"#
    case "custom.resources/get":
      resourceList.first { $0.contains(#""id":"\#(input?["id"]?.string ?? "")""#) }
    case "custom.resources/control":
      resourceList.first { $0.contains(#""id":"\#(input?["id"]?.string ?? "")""#) }.map { resource in
        let ticket = input?["action"]?.string == "release" ? "null"
          : #"{"ticket":"fixture","expiresAt":\#(now + 120_000),"path":"/resources/fixture","loopbackPort":9}"#
        return #"{"resource":\#(resource),"ticket":\#(ticket)}"#
      }
    case "custom.resources/snapshot":
      pictures[input?["id"]?.string ?? ""].map {
        #"{"mime":"image/png","data":"\#($0)","takenAt":\#(now - 2_000),"width":640,"height":400}"#
      }
    default: nil
    }
    return output.map { #"{"output":\#($0)}"# }
  }

  // MARK: Sessions

  struct Child {
    let id: String
    let title: String
    let agent: String
    let context: Double
    let cache: Double
    let cost: Double
    let started: Double
    var finished: Double? = nil
    var activity: String? = nil
  }

  static let live: [Child] = [
    Child(id: "ses_mac_c1", title: "Backend da Live Activity", agent: "opushigh", context: 285_100, cache: 0.995,
      cost: 2_759.40, started: 21, activity: #"{"name":"shell","state":{"status":"running","input":{"command":"bun test"}}}"#),
    Child(id: "ses_mac_c2", title: "iOS da Live Activity", agent: "opushigh", context: 223_500, cache: 0.991,
      cost: 4.60, started: 18, activity: #"{"name":"edit","state":{"status":"running","input":{"filePath":"packages/ios-custom/OpenCode/SessionsView.swift"}}}"#),
    Child(id: "ses_mac_c3", title: "Mapear apps Mac de agentes", agent: "explore", context: 116_400, cache: 0.826,
      cost: 2.09, started: 4, activity: #"{"name":"webfetch","state":{"status":"running","input":{"url":"https://agentastic.dev"}}}"#),
    Child(id: "ses_mac_c4", title: "Referências: Jean", agent: "terraxhigh", context: 91_400, cache: 0.606,
      cost: 1.12, started: 7),
  ]
  static let finished: [Child] = (1...41).map { (index: Int) -> Child in
    let step = Double(index * 6)
    return Child(id: String(format: "ses_mac_d%02d", index), title: "Subagente concluído \(index)", agent: "explore",
      context: 20_000 + Double(index) * 900, cache: 0.97, cost: 1.15, started: 60 + step, finished: 50 + step)
  }
  static let children: [Child] = live + [
    Child(id: "ses_mac_c5", title: "Capturar tela do web custom", agent: "terrahigh", context: 70_600, cache: 0.994,
      cost: 260.85, started: 40, finished: 25),
  ] + finished

  private func session(_ child: Child) -> String {
    // Output, input and cache reads add up to the context, and the reads give exactly the child's cache hit.
    let input = (child.context - 1_000) * (1 - child.cache)
    let read = (child.context - 1_000) * child.cache
    let tokens = #"{"input":\#(Int(input)),"output":1000,"reasoning":0,"cache":{"read":\#(Int(read)),"write":0}}"#
    let finished = child.finished.map { #","idle":\#(now - $0 * minute)"# } ?? ""
    let outcome = child.finished == nil ? "" : #","outcome":"succeeded""#
    return #"{"id":"\#(child.id)","parentID":"ses_mac_root","projectID":"prj_opencode2","title":"\#(child.title)","agent":"\#(child.agent)","model":{"id":"opus-5.5","providerID":"llm-proxy","variant":"high"},"cost":\#(child.cost),"tokens":\#(tokens),"context":{"id":"msg_\#(child.id)","tokens":\#(tokens),"model":{"id":"opus-5.5","providerID":"llm-proxy"}},"location":{"directory":"\#(root)"},"time":{"created":\#(now - child.started * minute),"updated":\#(now - (child.finished ?? 0) * minute)\#(finished)}\#(outcome)}"#
  }

  private struct Root {
    let id: String
    let title: String
    let directory: String
    let project: String
    var minutes: Double
    var outcome: String? = nil
    var viewed = true
    var permission = false
    var question = false
  }

  private var roots: [Root] {
    // Yesterday's rows sit before today's midnight, whatever time the fixture runs.
    let today = Date(timeIntervalSince1970: now / 1000)
    let midnight = (now - Calendar.current.startOfDay(for: today).timeIntervalSince1970 * 1000) / minute
    guard let arrival = MacBellChecks.arrival else { return fixedRoots(midnight: midnight) }
    // `-OpenCodeMacFixtureBell <s>`: two answers wait unread at launch and Conversas Android answers `s` seconds
    // later; a session opened records its view, like the server.
    let arrived = Date.now.timeIntervalSince1970 * 1000 >= now + arrival * 1000
    return fixedRoots(midnight: midnight).map { root in
      var root = root
      if ["ses_mac_live", "ses_mac_ios"].contains(root.id) || (root.id == "ses_mac_android" && arrived) {
        root.outcome = "succeeded"
        root.viewed = MacBellChecks.viewed(root.id)
      }
      if root.id == "ses_mac_android", arrived { root.minutes = -arrival / 60 }
      return root
    }
  }

  private func fixedRoots(midnight: Double) -> [Root] {
    [
      Root(id: MacFixture.rootID, title: "App Mac", directory: root, project: "prj_opencode2", minutes: 5),
      Root(id: "ses_mac_live", title: "Live activity", directory: home + "/Dev/abacato-v2", project: "prj_abacato",
        minutes: 12),
      Root(id: "ses_mac_sidebar", title: "Refatorar sidebar", directory: home + "/Dev/opencode2", project: "prj_opencode2",
        minutes: 120, permission: attention),
      Root(id: "ses_mac_docs", title: "Docs da arquitetura", directory: home + "/Dev/abacato-v2", project: "prj_abacato",
        minutes: 240, question: attention),
      Root(id: "ses_mac_qa", title: "Acerto QA autônomo", directory: home + "/Dev/abacato-v2", project: "prj_opencode2",
        minutes: 360, outcome: attention ? "failed" : nil, viewed: !attention),
      Root(id: "ses_mac_ios", title: "Live Activity iOS", directory: home + "/Dev/ios-live-activity",
        project: "prj_ios", minutes: max(midnight + 60, 18 * 60)),
      Root(id: "ses_mac_android", title: "Conversas Android", directory: home + "/Dev/android-chat",
        project: "prj_android", minutes: max(midnight + 120, 22 * 60)),
    ] + perfRoots
  }

  /// `-OpenCodeMacPerf`: a long history (`-OpenCodeMacPerfSessions <n>`, 200 by default) across the projects.
  private var perfRoots: [Root] {
    guard MacPerf.enabled else { return [] }
    let count = MacFixture.value("-OpenCodeMacPerfSessions").flatMap(Int.init) ?? 200
    let places = [(root, "prj_opencode2"), (home + "/Dev/abacato-v2", "prj_abacato"),
      (home + "/Dev/ios-live-activity", "prj_ios"), (home + "/Dev/android-chat", "prj_android")]
    return (0..<count).map { index in
      Root(id: String(format: "ses_mac_h%03d", index), title: "Sessão antiga \(index)",
        directory: places[index % places.count].0, project: places[index % places.count].1,
        minutes: 30 + Double(index) * 47)
    }
  }

  private func rootSession(_ value: Root) -> String {
    // `-OpenCodeMacPerf`: the streaming roots were just updated, as a real server's are on every step.
    let at = MacPerf.enabled && MacPerf.streaming.contains(value.id) ? Date.now.timeIntervalSince1970 * 1000
      : now - value.minutes * minute
    let isMain = value.id == MacFixture.rootID
    let tokens = isMain ? #"{"input":1200,"output":24000,"reasoning":0,"cache":{"read":2378000,"write":10700}}"# : #"{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}"#
    let context = isMain ? #","context":{"id":"msg_root","tokens":{"input":1400,"output":3200,"reasoning":0,"cache":{"read":274000,"write":0}},"model":{"id":"opus-5.5","providerID":"llm-proxy"}}"# : ""
    let outcome = value.outcome.map { #","outcome":"\#($0)""# } ?? ""
    return #"{"id":"\#(value.id)","projectID":"\#(value.project)","title":"\#(value.title)","agent":"build","model":{"id":"opus-5.5","providerID":"llm-proxy","variant":"xhigh"},"cost":\#(isMain ? 14.36 : 0.5),"tokens":\#(tokens)\#(context),"location":{"directory":"\#(value.directory)"},"time":{"created":\#(at - 60 * minute),"updated":\#(at),"idle":\#(at),"viewed":\#(value.viewed ? at : 0)}\#(outcome)}"#
  }

  private var navigation: String {
    roots.map { value in
      let at = now - value.minutes * minute
      let requests = (value.permission ? #","permissionAt":\#(at),"permissionCount":1"# : "")
        + (value.question ? #","questionAt":\#(at),"questionCount":1"# : "")
      return #"{"session":\#(rootSession(value)),"messageAt":\#(at)\#(requests)}"#
    }.joined(separator: ",")
  }

  private var sessions: [String: String] {
    Dictionary(uniqueKeysWithValues: roots.map { ($0.id, rootSession($0)) } + Self.children.map { ($0.id, session($0)) }
      + (searchFixture ? [("ses_mac_archived", archivedSession)] : []))
  }

  private var archivedSession: String {
    #"{"id":"ses_mac_archived","projectID":"prj_opencode2","title":"Live Activity · protótipo arquivado","location":{"directory":"\#(root)"},"time":{"created":\#(now - 5000 * minute),"updated":\#(now - 3000 * minute),"archived":\#(now - 3000 * minute)}}"#
  }

  private var projects: String {
    #"[{"id":"prj_opencode2","canonical":"\#(home)/Dev/opencode2","name":"opencode2","icon":{"color":"orange"},"sandboxes":["\#(root)"],"vcs":"git"},{"id":"prj_abacato","canonical":"\#(home)/Dev/abacato-v2","name":"abacato-v2","icon":{"color":"purple"},"sandboxes":[],"vcs":"git"},{"id":"prj_ios","canonical":"\#(home)/Dev/ios-live-activity","name":"ios-live-activity","icon":{"color":"green"},"sandboxes":[],"vcs":"git"},{"id":"prj_android","canonical":"\#(home)/Dev/android-chat","name":"android-chat","icon":{"color":"purple"},"sandboxes":[],"vcs":"git"}]"#
  }

  private var preferences: String {
    let extra = searchFixture ? #",{"worktree":"\#(home)/Dev/ios-live-activity","expanded":true}"# : ""
    return #"{"version":1,"revision":1,"data":{"projects":{"local":{"projects":[{"worktree":"\#(home)/Dev/abacato-v2","expanded":true},{"worktree":"\#(home)/Dev/opencode2","expanded":true}\#(extra)],"chatsIndex":2}},"pinnedSessions":[],"mutedSessions":[],"settings":{"autoApprove":false},"models":{"user":[{"providerID":"llm-proxy","modelID":"opus-5.5","visibility":"show"}],"variant":{},"default":{"providerID":"llm-proxy","modelID":"opus-5.5","variant":"xhigh"}}}}"#
  }

  /// `-OpenCodeMacAjustes question`: the root asks a question with options and its own answer.
  private var rootQuestion: String {
    guard MacAjustesChecks.mode == "question" else { return "" }
    return #"{"id":"frm_mac_root","sessionID":"ses_mac_root","title":"Questions","fields":[{"key":"modulo","type":"string","title":"Qual nome usar para o módulo de capturas?","options":[{"value":"capturas","label":"capturas"},{"value":"prints","label":"prints"}],"custom":true}],"metadata":{"kind":"question"}}"#
  }

  private var childPermission: String {
    #"{"id":"per_mac_c4","sessionID":"ses_mac_c4","action":"shell","resources":["gh api repos/jean/referencias"]}"#
  }

  // MARK: Transcripts

  private func transcript(_ id: String, limit: Int? = nil, cursor: String? = nil) -> String {
    if let child = Self.live.first(where: { $0.id == id }) {
      let tool = child.activity.map { #",{"type":"tool","id":"call_\#(id)",\#($0.dropFirst())"# } ?? ""
      return #"{"data":[{"id":"msg_\#(id)_a","type":"assistant","time":{"created":\#(now - minute)},"content":[{"type":"text","text":"Trabalhando em \#(child.title)\#(perfTick)."}\#(tool)]}]}"#
    }
    guard id == MacFixture.rootID else {
      return #"{"data":[{"id":"msg_\#(id)","type":"assistant","time":{"created":\#(now - 30 * minute)},"content":[{"type":"text","text":"Resumo sintético da sessão\#(MacPerf.streaming.contains(id) ? perfTick : "")."}]}]}"#
    }
    let messages = Array(rootMessages.reversed())
    // `-OpenCodeMacPerfLong`: pages of `limit`, newest first, like a real server; otherwise everything at once.
    guard MacFixture.value("-OpenCodeMacPerfLong") != nil, let limit else {
      return #"{"data":[\#(messages.joined(separator: ","))]}"#
    }
    let start = cursor.flatMap { Int($0.dropFirst()) } ?? 0
    let end = min(messages.count, start + limit)
    let next = end < messages.count ? #""o\#(end)""# : "null"
    return #"{"data":[\#(messages[min(start, end)..<end].joined(separator: ","))],"cursor":{"next":\#(next),"previous":null}}"#
  }

  /// `-OpenCodeMacPerfLong <n>`: `n` earlier turns before the root's two, each a prompt and an answer with Markdown
  /// (a heading, paragraphs, a list and code) and two tool calls, for the transcript's cost in a long conversation.
  private func longHistory(before start: Double) -> [String] {
    guard let count = MacFixture.value("-OpenCodeMacPerfLong").flatMap(Int.init), count > 0 else { return [] }
    let model = #"{"id":"opus-5.5","providerID":"llm-proxy","variant":"xhigh"}"#
    return (0..<count).flatMap { index -> [String] in
      let at = start - Double(count - index) * 4 * minute
      let answer = "## Etapa \(index)\n\nRevisei o fluxo \(index) da janela e o comportamento das colunas ao redimensionar. "
        + String(repeating: "O texto continua com detalhes da implementação e dos testes. ", count: 6)
        + "\n\n- Primeiro item da lista \(index)\n- Segundo item, com `código` inline\n- Terceiro item\n\n"
        + "```swift\nlet value\(index) = compute(\(index))\nprint(value\(index))\n```\n\n"
        + String(repeating: "Mais um parágrafo explicando a decisão tomada nesta etapa. ", count: 4)
      let encoded = String(decoding: try! JSONEncoder().encode(answer), as: UTF8.self)
      let tools = (0..<2).map { tool in
        #"{"type":"tool","id":"call_long_\#(index)_\#(tool)","name":"read","state":{"status":"completed","input":{"path":"\#(root)/File\#(index)_\#(tool).swift"},"metadata":{}},"time":{"created":\#(at + 2_000),"ran":\#(at + 2_000),"completed":\#(at + 4_000)}}"#
      }.joined(separator: ",")
      return [
        #"{"id":"msg_long_\#(index)_u","type":"user","time":{"created":\#(at)},"text":"Pedido \#(index): ajusta a etapa seguinte"}"#,
        #"{"id":"msg_long_\#(index)_a","type":"assistant","agent":"build","model":\#(model),"time":{"created":\#(at + 1_000),"completed":\#(at + 60_000)},"content":[\#(tools),{"type":"text","text":\#(encoded)}]}"#,
        #"{"id":"msg_long_\#(index)_i","type":"idle","time":{"created":\#(at + 61_000)}}"#,
      ]
    }
  }

  /// `-OpenCodeMacPerf`: previews of streaming sessions change as their text grows.
  private var perfTick: String { MacPerf.enabled ? " · \(Int(Date.now.timeIntervalSince1970 * 4))" : "" }

  /// Two turns, oldest first: the first ended (its answer, an activity card of 15 calls and the footer); the
  /// second runs the four live subagents, with one prompt waiting in the queue (`/inbox`).
  private var rootMessages: [String] {
    if MacDetailsFixture.mode != nil { return MacDetailsFixture.messages(now: now) }
    let first = now - 48 * minute
    let answer = "## Próxima etapa\n\nClaro! Vou criar o app de Mac com a coluna de contexto ao vivo, reaproveitando a coluna de Sessões do iPhone.\n\n- A janela tem três colunas: Sessões, o chat e o Contexto.\n- O Contexto mostra subagentes, tarefas e recursos em uso.\n\nO componente principal da lista de sessões está em `SessionColumnSections.swift`, e o cabeçalho em `packages/ios-custom/OpenCode/SessionColumn/SessionColumnHeader.swift`."
    let encoded = String(decoding: try! JSONEncoder().encode(answer), as: UTF8.self)
    var offset = 20.0
    func call(_ id: String, _ name: String, _ input: String, seconds: Double, metadata: String = "{}") -> String {
      let start = first + offset * 1000
      offset += seconds + 2
      return #"{"type":"tool","id":"call_\#(id)","name":"\#(name)","state":{"status":"completed","input":\#(input),"metadata":\#(metadata)},"time":{"created":\#(start),"ran":\#(start),"completed":\#(start + seconds * 1000)}}"#
    }
    let files = "packages/ios-custom/OpenCode"
    var tools: [String] = [
      call("r1", "read", #"{"path":"\#(root)/\#(files)/SessionsView.swift"}"#, seconds: 12),
      call("s1", "shell", #"{"command":"git status"}"#, seconds: 6),
      call("a1", "subagent", #"{"agent":"explore","description":"Mapear apps Mac de agentes"}"#, seconds: 72,
        metadata: #"{"sessionID":"ses_mac_d01"}"#),
      call("e1", "edit", #"{"path":"\#(root)/\#(files)/ChatView.swift"}"#, seconds: 48,
        metadata: #"{"files":[{"file":"\#(files)/ChatView.swift","patch":"@@ -1,3 +1,12 @@","additions":12,"deletions":3,"status":"modified"}]}"#),
    ]
    for index in 1...11 {
      let input: String = index % 3 == 0
        ? #"{"pattern":"SessionRow","path":"\#(root)/\#(files)"}"#
        : #"{"path":"\#(root)/\#(files)/File\#(index).swift"}"#
      tools.append(call("m\(index)", index % 3 == 0 ? "grep" : "read", input, seconds: 7 + Double(index)))
    }
    let done = first + (offset + 30) * 1000
    // The `subagent` calls that started the live subagents, so their elapsed time counts from the call.
    let calls = Self.live.map { child in
      let start = now - child.started * minute
      return #"{"type":"tool","id":"call_\#(child.id)","name":"subagent","state":{"status":"running","input":{"agent":"\#(child.agent)","description":"\#(child.title)"},"metadata":{"sessionID":"\#(child.id)"}},"time":{"created":\#(start),"ran":\#(start)}}"#
    }.joined(separator: ",")
    let model = #"{"id":"opus-5.5","providerID":"llm-proxy","variant":"xhigh"}"#
    return longHistory(before: first) + [
      #"{"id":"msg_root_1","type":"user","time":{"created":\#(first)},"text":"Gera o app de Mac com a coluna de contexto ao vivo"}"#,
      #"{"id":"msg_root_2","type":"assistant","agent":"build","model":\#(model),"time":{"created":\#(first + 5_000),"completed":\#(done)},"content":[{"type":"text","text":\#(encoded)},\#(tools.joined(separator: ","))]}"#,
      #"{"id":"msg_root_3","type":"idle","time":{"created":\#(done + 1_000)}}"#,
      #"{"id":"msg_root_4","type":"user","time":{"created":\#(now - 25 * minute)},"text":"Agora liga os subagentes ao vivo na coluna 3"}"#,
      #"{"id":"msg_root_5","type":"assistant","agent":"build","model":\#(model),"time":{"created":\#(now - 134_000)},"content":[\#(calls)]}"#,
    ]
  }

  // MARK: Resources

  private var resourceList: [String] {
    func resource(_ id: String, _ kind: String, _ label: String, owner: String, state: String, meta: String,
      used: Double) -> String {
      #"{"id":"\#(id)","kind":"\#(kind)","label":"\#(label)","owner":{"sessionID":"\#(owner)","rootSessionID":"ses_mac_root"},"state":"\#(state)","meta":\#(meta),"discoveredAt":\#(now - 90 * minute),"lastUsedAt":\#(now - used * minute),"updatedAt":\#(now - used * minute),"live":{"stream":true,"input":true}}"#
    }
    return [
      resource("res_iphone", "ios-simulator", "iPhone 17 Pro", owner: "ses_mac_c2", state: "agent",
        meta: #"{"kind":"ios-simulator","device":"iPhone 17 Pro","runtime":"iOS 27.0"}"#, used: 0),
      resource("res_chrome", "chrome", "Chrome", owner: "ses_mac_c3", state: "agent",
        meta: #"{"kind":"chrome","url":"http://localhost:4177/","title":"OpenCode"}"#, used: 1),
      resource("res_pixel", "android-emulator", "Pixel 9", owner: "ses_mac_root", state: "idle",
        meta: #"{"kind":"android-emulator","avd":"Pixel_9"}"#, used: 8),
    ]
  }
  private var resources: String { resourceList.joined(separator: ",") }

  // MARK: Files

  private var changes: String {
    #"[{"file":"packages/ios-custom/OpenCode/SessionColumn/SessionColumnHeader.swift","additions":12,"deletions":3,"status":"modified"},{"file":"packages/ios-custom/OpenCode/SessionColumn/SessionColumnSections.swift","additions":19,"deletions":4,"status":"modified"},{"file":"packages/ios-custom/OpenCode/SessionColumn/SessionRowView.swift","additions":8,"deletions":2,"status":"modified"},{"file":"packages/ios-custom/OpenCode/SessionStore.swift","additions":21,"deletions":5,"status":"modified"},{"file":"packages/ios-custom/OpenCodeMac/MacWindow.swift","additions":64,"deletions":0,"status":"added"},{"file":"packages/ios-custom/README.md","additions":4,"deletions":0,"status":"modified"}]"#
  }

  /// Lists this Mac's folder, folders first, like `/api/fs/list`. Paths are absolute (Location `/`).
  private func list(_ path: String) -> String? {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
    let entries = names.compactMap { name -> (String, Bool)? in
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &directory) else { return nil }
      return (name, directory.boolValue)
    }.sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    let data = entries.map { name, directory in
      #"{"path":"\#(String((path + "/" + name).dropFirst()))","type":"\#(directory ? "directory" : "file")"}"#
    }
    return #"{"location":{"directory":"/"},"data":[\#(data.joined(separator: ","))]}"#
  }

  private func find(_ query: String) -> String {
    var found: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: root)
    while let next = enumerator?.nextObject() as? String, found.count < 200 {
      if next.hasPrefix(".git") || next.contains("node_modules") || next.contains(".build") { continue }
      if next.hasSuffix(query) || URL(fileURLWithPath: next).lastPathComponent.localizedCaseInsensitiveContains(query) {
        found.append(#"{"path":"\#(next)","type":"file"}"#)
      }
    }
    return #"{"data":[\#(found.joined(separator: ","))]}"#
  }

  /// `-OpenCodeMacLargeCatalog <n>`: a gateway-sized catalog (the fixture's three models, then `n` more across
  /// two providers with up to six efforts each), to measure the model picker.
  private var largeCatalog: String {
    let count = MacFixture.value("-OpenCodeMacLargeCatalog").flatMap(Int.init) ?? 300
    let efforts = ["none", "low", "medium", "high", "xhigh", "max"]
    let extra = (1...max(1, count)).map { index in
      let variants = efforts.suffix(index % 7).map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
      return #"{"id":"model-\#(index)","providerID":"\#(index % 2 == 0 ? "vercel" : "personal")","name":"Modelo \#(index)","variants":[\#(variants)],"limit":{"context":400000}}"#
    }
    return #"{"data":[{"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","variants":[{"id":"high"},{"id":"xhigh"}],"limit":{"context":1000000}},\#(extra.joined(separator: ","))]}"#
  }

  private struct RPC: Decodable { let input: [String: JSONValue]? }
}

/// Synthetic live pictures for the fixture's resources, drawn once at launch.
@MainActor enum MacFixturePictures {
  static func make() -> [String: String] {
    [
      "res_iphone": draw(portrait: true, title: "Sessões", accent: NSColor(red: 0.96, green: 0.5, blue: 0.2, alpha: 1)),
      "res_pixel": draw(portrait: true, title: "Android", accent: NSColor(red: 0.3, green: 0.75, blue: 0.5, alpha: 1)),
      "res_chrome": draw(portrait: false, title: "localhost:4177 · OpenCode", accent: NSColor(red: 0.96, green: 0.5, blue: 0.2, alpha: 1)),
    ]
  }

  private static func draw(portrait: Bool, title: String, accent: NSColor) -> String {
    let size = portrait ? NSSize(width: 360, height: 720) : NSSize(width: 800, height: 500)
    let image = NSImage(size: size, flipped: true) { rect in
      NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1).setFill()
      rect.fill()
      NSColor(white: 0.16, alpha: 1).setFill()
      NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: rect.width, height: portrait ? 70 : 44), xRadius: 0, yRadius: 0).fill()
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: portrait ? 30 : 22, weight: .bold), .foregroundColor: NSColor.white,
      ]
      (title as NSString).draw(at: NSPoint(x: 24, y: portrait ? 90 : 64), withAttributes: attributes)
      for row in 0..<(portrait ? 7 : 5) {
        let y = (portrait ? 150 : 110) + CGFloat(row) * (portrait ? 72 : 64)
        accent.withAlphaComponent(row == 0 ? 0.9 : 0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: 24, y: y, width: 40, height: 40)).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: y + 6, width: rect.width * 0.5, height: 10), xRadius: 5, yRadius: 5).fill()
        NSColor(white: 0.45, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80, y: y + 24, width: rect.width * 0.35, height: 8), xRadius: 4, yRadius: 4).fill()
      }
      return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
    return png.base64EncodedString()
  }
}
#endif
