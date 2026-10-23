import Foundation
import Testing

@testable import OpenCodeKit

@Test func mcpOrderPrioritizesConnectionsThenComputerSafariAndNamesInBothGroups() {
  for connected in [false, true] {
    let state: MCPServer.State = connected ? .connected : .disabled
    let servers = ["zeta", "safari-devtools", "alpha", "codex-computer-use", "claude-in-chrome"]
      .map { MCPServer(name: $0, state: state) }
    #expect(MCPServer.ordered(servers).map(\.name) == [
      "codex-computer-use", "safari-devtools", "alpha", "claude-in-chrome", "zeta",
    ])
  }
  #expect(MCPServer.ordered([
    .init(name: "codex-computer-use", state: .disabled),
    .init(name: "safari-devtools", state: .failed),
    .init(name: "zeta", state: .connected), .init(name: "alpha", state: .needsAuth),
    .init(name: "beta", state: .pending),
  ]).map(\.name) == ["zeta", "codex-computer-use", "safari-devtools", "alpha", "beta"])
}

@Test func mcpOrderFreezesWhileVisibleAndResortsOnReopenIncludingPreview() {
  let servers = [MCPServer(name: "safari-devtools", state: .connected),
    MCPServer(name: "codex-computer-use", state: .disabled)]
  var order = MCPChipOrder()
  order.open(servers)
  let changed = servers.map { $0.preview($0.name == "codex-computer-use") }
  order.open(changed)
  #expect(order.arrange(changed).map(\.name) == ["safari-devtools", "codex-computer-use"])
  #expect(order.arrange(changed).first?.status.status == .disabled)
  order.close()
  order.open(changed)
  #expect(order.arrange(changed).map(\.name) == ["codex-computer-use", "safari-devtools"])
}

@Test func mcpPillCountsOnlyConnectedAndHidesEmptyOrUnsupported() {
  let servers = [MCPServer.State.connected, .disabled, .failed, .needsAuth, .pending, .unknown]
    .enumerated().map { MCPServer(name: String($0.offset), state: $0.element) }
  let summary = MCPSummary(servers)
  #expect(summary.visible && summary.connected == 1 && summary.total == 6)
  #expect(summary.label == "MCP · 1/6")
  #expect(summary.accessibilityLabel == "MCPs, 1 de 6 conectados")
  #expect(!MCPSummary([]).visible)
  #expect(!MCPSummary(servers, unsupported: true).visible)
  #expect(MCPSummary(servers.filter { $0.status.status != .connected }).connected == 0)
  #expect(MCPSummary.isUnsupported(ClientError.http(404)))
  #expect(MCPSummary.isUnsupported(ClientError.http(501)))
  #expect(!MCPSummary.isUnsupported(ClientError.http(503)))
  #expect(!MCPSummary.isUnsupported(ClientError.http(401)))
}

private actor MCPContractHTTP {
  var requests: [URLRequest] = []
  func respond(_ request: URLRequest) -> (Data, URLResponse) {
    requests.append(request)
    let payload = request.url!.path == "/api/mcp" ? #"{"data":[{"name":"safe","status":{"status":"connected"}}]}"# : "[]"
    return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@Test func mcpHTTPKeepsInstalledLocationScopedListConfigAndBodylessToggleContracts() async throws {
  let http = MCPContractHTTP()
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!)) { await http.respond($0) }
  let directory = "/repo child & worktree"
  #expect(try await client.mcpServers(directory: directory).first?.status.status == .connected)
  _ = try await client.newSessionConfiguration(directory: directory)
  try await client.toggleMCP("safe", enabled: false, directory: directory)
  try await client.toggleMCP("safe", enabled: true, directory: directory)
  let requests = await http.requests
  #expect(requests.map { $0.url!.path } == ["/api/mcp", "/api/config",
    "/api/experimental/mcp/safe/disconnect", "/api/experimental/mcp/safe/connect"])
  #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "POST"])
  #expect(requests.allSatisfy { $0.httpBody == nil })
  #expect(requests.allSatisfy {
    URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "location[directory]", value: directory)]
  })
}
