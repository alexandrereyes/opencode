#if DEBUG
import Foundation

extension OpenCodeClient {
  /// The fixture never forwards requests, including MCP mutations, to a real process.
  public static func mcpFixture(configuration: ServerConfiguration, scenario: String = "") -> Self {
    let fixture = MCPFixtureHTTP(scenario: scenario)
    return Self(configuration: configuration) { try await fixture.respond($0) }
  }
}

private actor MCPFixtureHTTP {
  let scenario: String
  var servers: [MCPServer] = [
    .init(name: "playwright", state: .needsAuth), .init(name: "figma", state: .failed),
    .init(name: "claude-in-chrome", state: .disabled),
    .init(name: "codex-computer-use", state: .disabled),
    .init(name: "safari-devtools", state: .connected),
  ]
  let directory = "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/custom-sandbox-4177/repos/ios-conversation"
  init(scenario: String) { self.scenario = scenario }
  func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = request.url!
    let path = url.path
    let session = "{\"id\":\"ses_mcp_fixture\",\"projectID\":\"mcp-project\",\"title\":\"MCPs na conversa\",\"agent\":\"build\",\"model\":{\"id\":\"opus\",\"providerID\":\"fixture\",\"variant\":\"xhigh\"},\"location\":{\"directory\":\"\(directory)\"},\"time\":{\"created\":1792742400000,\"updated\":1792742400000}}"
    let model = #"{"id":"opus","providerID":"fixture","name":"Opus 5.5","limit":{"context":200000},"variants":[{"id":"xhigh"}]}"#
    let projects = "[{\"id\":\"mcp-project\",\"canonical\":\"\(directory)\",\"sandboxes\":[],\"name\":\"OpenCode iOS\"}]"
    let preferences = "{\"revision\":1,\"data\":{\"projects\":{\"local\":{\"projects\":[{\"worktree\":\"\(directory)\",\"expanded\":true}]}},\"pinnedSessions\":[],\"settings\":{\"autoApprove\":false}}}"
    var status = 200
    let json: String
    if path.hasPrefix("/api/experimental/mcp/") {
      let name = url.pathComponents[4]
      guard name != "playwright" else { throw ClientError.operation("OAuth não permitido na fixture") }
      try await Task.sleep(for: .seconds(scenario == "pending" ? 8 : 2))
      status = name == "figma" ? 503 : 204
      if status == 204 {
        servers = servers.map { $0.name == name ? .init(name: name, state: path.hasSuffix("/connect") ? .connected : .disabled) : $0 }
      }
      json = ""
    } else {
      switch path {
      case "/api/mcp":
        if scenario == "unsupported" { status = 404 }
        json = String(decoding: try JSONEncoder().encode(["data": scenario == "empty" ? [] : servers]), as: UTF8.self)
      case "/api/info": json = #"{"version":"fixture"}"#
      case "/api/session/ses_mcp_fixture": json = "{\"data\":\(session)}"
      case "/api/session/active": json = #"{"data":{}}"#
      case "/api/session": json = #"{"data":[],"cursor":{}}"#
      case "/api/session/ses_mcp_fixture/inbox": json = #"{"data":[]}"#
      case "/api/session/ses_mcp_fixture/view": json = "{}"
      case "/api/model": json = "{\"data\":[\(model)]}"
      case "/api/model/default": json = "{\"data\":\(model)}"
      case "/api/agent": json = #"{"data":[{"id":"build","name":"Build","mode":"primary"}]}"#
      case "/api/provider", "/api/shell": json = #"{"data":[]}"#
      case "/api/project": json = projects
      case "/api/worktree": json = "[]"
      case "/api/vcs": json = #"{"data":{"provider":"git","branch":{"current":"ios-testflight"}}}"#
      case "/api/config": json = "[]"
      case "/api/rpc/custom.preferences/get", "/api/rpc/custom.preferences/mutate":
        json = "{\"output\":\(preferences)}"
      case "/api/rpc/custom.navigation/list":
        json = "{\"output\":{\"data\":[{\"session\":\(session)}]}}"
      case "/api/rpc/custom.chats/info": json = #"{"output":{"root":"/fixture-chats"}}"#
      case "/api/rpc/custom.requests/permissions": json = #"{"output":[]}"#
      case "/api/rpc/custom.worktrees/available": json = #"{"output":true}"#
      case "/api/rpc/custom.worktrees/locate", "/api/rpc/custom.worktrees/branches": json = #"{"output":[]}"#
      case "/api/rpc/custom.session-family/snapshot":
        json = #"{"output":{"count":0,"permissions":[],"forms":[],"active":[]}}"#
      case "/api/rpc/custom.session-family/page": json = #"{"output":{"data":[]}}"#
      case "/api/rpc/custom.transcript/list":
        json = #"{"output":{"data":[{"id":"msg_mcp_assistant","type":"assistant","time":{"created":1792742460000,"completed":1792742470000},"finish":"stop","content":[{"id":"part_mcp","type":"text","text":"Os MCPs ficam disponíveis no campo de mensagem.\n\nToque na pílula para ver todos os servidores deste diretório, sem sair da conversa.\n\nO texto e o teclado permanecem no lugar."}]},{"id":"msg_mcp_user","type":"user","time":{"created":1792742400000},"text":"Quero pequenos chips dos MCPs aqui na conversa."}]}}"#
      default: throw URLError(.notConnectedToInternet)
      }
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
#endif
