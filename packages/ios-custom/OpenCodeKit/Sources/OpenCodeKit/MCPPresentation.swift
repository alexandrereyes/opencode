import Foundation

public struct MCPChipOrder: Sendable {
  private var names: [String] = []
  public private(set) var visible = false
  public init() {}
  public mutating func open(_ servers: [MCPServer]) {
    guard !visible, !servers.isEmpty else { return }
    visible = true
    names = MCPServer.ordered(servers).map(\.name)
  }
  public mutating func close() { visible = false }
  public func arrange(_ servers: [MCPServer]) -> [MCPServer] {
    guard visible else { return MCPServer.ordered(servers) }
    return names.compactMap { name in servers.first { $0.name == name } }
      + MCPServer.ordered(servers.filter { !names.contains($0.name) })
  }
}

public struct MCPSummary: Sendable, Equatable {
  public let connected: Int
  public let total: Int
  public let unsupported: Bool
  public init(_ servers: [MCPServer], unsupported: Bool = false) {
    connected = servers.filter { $0.status.status == .connected }.count
    total = servers.count
    self.unsupported = unsupported
  }
  public var visible: Bool { total > 0 && !unsupported }
  public var label: String { "MCP · \(connected)/\(total)" }
  public var accessibilityLabel: String { "MCPs, \(connected) de \(total) conectados" }
  public static func isUnsupported(_ error: any Error) -> Bool {
    if case ClientError.http(let code) = error { return code == 404 || code == 405 || code == 501 }
    return false
  }
}
