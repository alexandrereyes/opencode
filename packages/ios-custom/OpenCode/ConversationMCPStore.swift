import Foundation
import Observation
import OpenCodeKit

@MainActor @Observable final class ConversationMCPStore {
  private(set) var servers: [MCPServer] = []
  private(set) var loading = false
  private(set) var failed = false
  private(set) var unsupported = false
  private(set) var directory: String?
  private(set) var toggling: Set<String> = []
  private var order = MCPChipOrder()
  private let client: OpenCodeClient
  private let toast: ToastCenter
  @ObservationIgnored var panelFrame = CGRect.zero
  @ObservationIgnored var pillFrame = CGRect.zero
  @ObservationIgnored var transcriptFrame = CGRect.zero
  /// Called after the server list changes, so app mentions follow connected app MCPs.
  @ObservationIgnored var changed: (() -> Void)?
  var isOpen: Bool { order.visible }
  var summary: MCPSummary { MCPSummary(servers, unsupported: unsupported) }
  var chips: [MCPServer] {
    order.arrange(servers).map { server in
      guard toggling.contains(server.name) else { return server }
      var value = server
      value.status = .init(.pending)
      return value
    }
  }
  init(client: OpenCodeClient, toast: ToastCenter) {
    self.client = client
    self.toast = toast
  }
  func load(directory: String?) async {
    guard directory != self.directory else { return }
    close()
    servers = []
    toggling = []
    unsupported = false
    self.directory = directory
    await refresh()
  }
  func open() { order.open(servers) }
  // Mutating `order` notifies observers even when already closed; the conversation
  // calls this on every composer trigger change and would re-render its transcript.
  func close() { if order.visible { order.close() } }
  func refresh() async {
    guard let directory else { return }
    loading = true
    failed = false
    defer { if directory == self.directory { loading = false } }
    do {
      let values = try await client.mcpServers(directory: directory)
      try Task.checkCancellation()
      guard directory == self.directory else { return }
      servers = values
      unsupported = false
      if values.isEmpty { close() }
      changed?()
    } catch {
      guard !Task.isCancelled, directory == self.directory else { return }
      failed = true
      unsupported = MCPSummary.isUnsupported(error)
      if unsupported { close() }
    }
  }
  func toggle(_ server: MCPServer) async {
    guard let directory, !toggling.contains(server.name) else { return }
    switch server.toggle(destination: .root) {
    case .unavailable, .intent: return
    case .login:
      toast.show("Faça o login de \(server.name) pelo app web para conectar este MCP.", kind: .error)
    case .live:
      toggling.insert(server.name)
      defer { if directory == self.directory { toggling.remove(server.name) } }
      do {
        try await client.toggleMCP(server.name, enabled: !server.enabled, directory: directory)
        let updated = try await client.mcpServers(directory: directory)
        guard directory == self.directory else { return }
        servers = updated
        changed?()
        guard let value = updated.first(where: { $0.name == server.name }),
          value.status.status == (server.enabled ? .disabled : .connected)
        else { throw MCPUIError() }
        Haptics.play(.selection)
      } catch {
        guard directory == self.directory else { return }
        toast.show("Não foi possível alterar \(server.name). \(error.localizedDescription)", kind: .error)
        await refresh()
      }
    }
  }
}
