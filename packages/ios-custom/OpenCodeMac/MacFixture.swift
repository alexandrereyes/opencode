#if DEBUG
import AppKit
import OpenCodeKit

/// A closed, in-memory server for captures and offline checks (`-OpenCodeMacFixture contexto`). It answers the
/// same endpoints the app reads from a real server, with synthetic sessions, subagents, tasks, resources and
/// working-copy changes; folders and files come from this Mac's checkout (`-OpenCodeMacFixtureRoot <path>`), so
/// Arquivos lists real files. No request ever leaves the process.
@MainActor struct MacFixture {
  static let configuration = ServerConfiguration(url: URL(string: "http://127.0.0.1:9")!)
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
    case "/api/session": return #"{"data":[],"cursor":{}}"#
    case "/api/model": return #"{"data":[{"id":"opus-5.5","providerID":"llm-proxy","name":"Opus 5.5","variants":[{"id":"high"},{"id":"xhigh"}],"limit":{"context":1000000}}]}"#
    case "/api/agent":
      return #"{"data":["# + ["build", "explore", "opushigh", "terraxhigh", "terrahigh"].map {
        #"{"id":"\#($0)","name":"\#($0)","mode":"\#($0 == "build" ? "primary" : "subagent")"}"#
      }.joined(separator: ",") + "]}"
    case "/api/shell":
      return #"{"data":[{"id":"shl_dev","status":"running","command":"bun run dev --port 4177","metadata":{"sessionID":"ses_mac_root"},"time":{"started":\#(now - 12 * minute)}},{"id":"shl_test","status":"running","command":"xcodebuild test -scheme OpenCode","metadata":{"sessionID":"ses_mac_root"},"time":{"started":\#(now - 3 * minute)}}]}"#
    case "/api/vcs/diff": return "{\"data\":\(changes)}"
    case "/api/mcp":
      return #"{"data":[{"name":"chrome-devtools","status":{"status":"connected"}},{"name":"github","status":{"status":"disabled"}},{"name":"linear","status":{"status":"disabled"}},{"name":"sentry","status":{"status":"needs_auth"}}]}"#
    case "/api/session/\(MacFixture.rootID)/inbox":
      return #"{"data":[{"id":"inb_mac_1","sessionID":"\#(MacFixture.rootID)","type":"user","delivery":"queue","payload":{"text":"Depois roda os testes do Mac e do iPhone"},"time":{"created":\#(now - minute)}}]}"#
    case "/api/fs/list":
      return list(query.first { $0.name == "path" }?.value ?? query.first { $0.name == "location[directory]" }?.value ?? root)
    case "/api/fs/find": return find(query.first { $0.name == "query" }?.value ?? "")
    default:
      if path.hasPrefix("/api/session/") {
        let id = String(path.dropFirst("/api/session/".count))
        return sessions[id].map { "{\"data\":\($0)}" }
      }
      return nil
    }
  }

  private func rpc(_ name: String, _ input: [String: JSONValue]?) -> String? {
    let output: String? = switch name {
    case "custom.navigation/list": #"{"data":[\#(navigation)],"next":null}"#
    case "custom.preferences/get": preferences
    case "custom.requests/permissions": "[]"
    case "custom.chats/info": #"{"root":"\#(home)/Chats"}"#
    case "custom.master/info": #"{"version":1,"agent":"build","model":{"id":"opus-5.5","providerID":"llm-proxy"}}"#
    case "custom.directories/home": #"{"path":"\#(home)"}"#
    case "custom.worktrees/locate":
      "[" + (input?["directories"]?.array?.compactMap(\.string) ?? []).map { directory in
        let branch = directory == root ? "mac-app" : "main"
        return #"{"directory":"\#(directory)","worktree":"\#(directory)","canonical":"\#(directory)","branch":"\#(branch)"}"#
      }.joined(separator: ",") + "]"
    case "custom.session-family/snapshot":
      input?["sessionID"]?.string == MacFixture.rootID
        ? #"{"count":\#(Self.children.count),"cost":63.89,"active":[\#(Self.live.map { session($0) }.joined(separator: ","))],"forms":[],"permissions":[\#(childPermission)]}"#
        : #"{"count":0,"active":[],"forms":[],"permissions":[]}"#
    case "custom.session-family/page":
      input?["sessionID"]?.string == MacFixture.rootID
        ? #"{"data":[\#(Self.children.map { session($0) }.joined(separator: ","))],"next":null}"#
        : #"{"data":[],"next":null}"#
    case "custom.transcript/list": transcript(input?["sessionID"]?.string ?? "")
    case "custom.resources/list": #"{"resources":[\#(resources)]}"#
    case "custom.resources/get":
      resourceList.first { $0.contains(#""id":"\#(input?["id"]?.string ?? "")""#) }
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
      cost: 7.27, started: 21, activity: #"{"name":"shell","state":{"status":"running","input":{"command":"bun test"}}}"#),
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
      cost: 0.24, started: 40, finished: 25),
  ] + finished

  private func session(_ child: Child) -> String {
    // Output, input and cache reads add up to the context, and the reads give exactly the child's cache hit.
    let input = (child.context - 1_000) * (1 - child.cache)
    let read = (child.context - 1_000) * child.cache
    let tokens = #"{"input":\#(Int(input)),"output":1000,"reasoning":0,"cache":{"read":\#(Int(read)),"write":0}}"#
    let finished = child.finished.map { #","idle":\#(now - $0 * minute)"# } ?? ""
    let outcome = child.finished == nil ? "" : #","outcome":"succeeded""#
    return #"{"id":"\#(child.id)","parentID":"ses_mac_root","projectID":"prj_opencode2","title":"\#(child.title)","agent":"\#(child.agent)","model":{"id":"opus-5.5","providerID":"llm-proxy"},"cost":\#(child.cost),"tokens":\#(tokens),"context":{"id":"msg_\#(child.id)","tokens":\#(tokens),"model":{"id":"opus-5.5","providerID":"llm-proxy"}},"location":{"directory":"\#(root)"},"time":{"created":\#(now - child.started * minute),"updated":\#(now - (child.finished ?? 0) * minute)\#(finished)}\#(outcome)}"#
  }

  private struct Root {
    let id: String
    let title: String
    let directory: String
    let project: String
    let minutes: Double
    var outcome: String? = nil
    var viewed = true
  }

  private var roots: [Root] {
    // Yesterday's rows sit before today's midnight, whatever time the fixture runs.
    let today = Date(timeIntervalSince1970: now / 1000)
    let midnight = (now - Calendar.current.startOfDay(for: today).timeIntervalSince1970 * 1000) / minute
    return [
      Root(id: MacFixture.rootID, title: "App Mac", directory: root, project: "prj_opencode2", minutes: 5),
      Root(id: "ses_mac_live", title: "Live activity", directory: home + "/Dev/abacato-v2", project: "prj_abacato",
        minutes: 12),
      Root(id: "ses_mac_sidebar", title: "Refatorar sidebar", directory: home + "/Dev/opencode2", project: "prj_opencode2",
        minutes: 120),
      Root(id: "ses_mac_docs", title: "Docs da arquitetura", directory: home + "/Dev/abacato-v2", project: "prj_abacato",
        minutes: 240),
      Root(id: "ses_mac_qa", title: "Acerto QA autônomo", directory: home + "/Dev/abacato-v2", project: "prj_opencode2",
        minutes: 360),
      Root(id: "ses_mac_ios", title: "Live Activity iOS", directory: home + "/Dev/ios-live-activity",
        project: "prj_ios", minutes: max(midnight + 60, 18 * 60)),
      Root(id: "ses_mac_android", title: "Conversas Android", directory: home + "/Dev/android-chat",
        project: "prj_android", minutes: max(midnight + 120, 22 * 60)),
    ]
  }

  private func rootSession(_ value: Root) -> String {
    let at = now - value.minutes * minute
    let isMain = value.id == MacFixture.rootID
    let tokens = isMain ? #"{"input":1200,"output":24000,"reasoning":0,"cache":{"read":2378000,"write":10700}}"# : #"{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}"#
    let context = isMain ? #","context":{"id":"msg_root","tokens":{"input":1400,"output":3200,"reasoning":0,"cache":{"read":274000,"write":0}},"model":{"id":"opus-5.5","providerID":"llm-proxy"}}"# : ""
    let outcome = value.outcome.map { #","outcome":"\#($0)""# } ?? ""
    return #"{"id":"\#(value.id)","projectID":"\#(value.project)","title":"\#(value.title)","agent":"build","model":{"id":"opus-5.5","providerID":"llm-proxy","variant":"xhigh"},"cost":\#(isMain ? 14.36 : 0.5),"tokens":\#(tokens)\#(context),"location":{"directory":"\#(value.directory)"},"time":{"created":\#(at - 60 * minute),"updated":\#(at),"idle":\#(at),"viewed":\#(value.viewed ? at : 0)}\#(outcome)}"#
  }

  private var navigation: String {
    roots.map { value in
      let at = now - value.minutes * minute
      return #"{"session":\#(rootSession(value)),"messageAt":\#(at)}"#
    }.joined(separator: ",")
  }

  private var sessions: [String: String] {
    Dictionary(uniqueKeysWithValues: roots.map { ($0.id, rootSession($0)) } + Self.children.map { ($0.id, session($0)) })
  }

  private var projects: String {
    #"[{"id":"prj_opencode2","canonical":"\#(home)/Dev/opencode2","name":"opencode2","icon":{"color":"orange"},"sandboxes":["\#(root)"],"vcs":"git"},{"id":"prj_abacato","canonical":"\#(home)/Dev/abacato-v2","name":"abacato-v2","icon":{"color":"purple"},"sandboxes":[],"vcs":"git"},{"id":"prj_ios","canonical":"\#(home)/Dev/ios-live-activity","name":"ios-live-activity","icon":{"color":"green"},"sandboxes":[],"vcs":"git"},{"id":"prj_android","canonical":"\#(home)/Dev/android-chat","name":"android-chat","icon":{"color":"purple"},"sandboxes":[],"vcs":"git"}]"#
  }

  private var preferences: String {
    #"{"version":1,"revision":1,"data":{"projects":{"local":{"projects":[{"worktree":"\#(home)/Dev/abacato-v2","expanded":true},{"worktree":"\#(home)/Dev/opencode2","expanded":true}],"chatsIndex":2}},"pinnedSessions":[],"mutedSessions":[],"settings":{"autoApprove":false},"models":{"user":[{"providerID":"llm-proxy","modelID":"opus-5.5","visibility":"show"}],"variant":{},"default":{"providerID":"llm-proxy","modelID":"opus-5.5","variant":"xhigh"}}}}"#
  }

  private var childPermission: String {
    #"{"id":"per_mac_c4","sessionID":"ses_mac_c4","action":"shell","resources":["gh api repos/jean/referencias"]}"#
  }

  // MARK: Transcripts

  private func transcript(_ id: String) -> String {
    if let child = Self.live.first(where: { $0.id == id }) {
      let tool = child.activity.map { #",{"type":"tool","id":"call_\#(id)",\#($0.dropFirst())"# } ?? ""
      return #"{"data":[{"id":"msg_\#(id)_a","type":"assistant","time":{"created":\#(now - minute)},"content":[{"type":"text","text":"Trabalhando em \#(child.title)."}\#(tool)]}]}"#
    }
    guard id == MacFixture.rootID else {
      return #"{"data":[{"id":"msg_\#(id)","type":"assistant","time":{"created":\#(now - 30 * minute)},"content":[{"type":"text","text":"Resumo sintético da sessão."}]}]}"#
    }
    return #"{"data":[\#(rootMessages.reversed().joined(separator: ","))]}"#
  }

  /// Two turns, oldest first: the first ended (its answer, an activity card of 15 calls and the footer); the
  /// second runs the four live subagents, with one prompt waiting in the queue (`/inbox`).
  private var rootMessages: [String] {
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
    return [
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
