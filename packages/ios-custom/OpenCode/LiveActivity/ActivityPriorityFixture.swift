#if DEBUG
import ActivityKit
import OpenCodeKit
import SwiftUI

/// Real ActivityKit drivers with a closed transport: no APNs registration, audio or model calls.
struct ActivityPriorityFixtureRoot: View {
  @State private var voice = VoiceActivityDriver()
  @State private var agents = AgentsActivityDriver()
  @State private var state = VoiceState()
  @State private var report = "Preparando"
  @State private var id = UUID()
  private let configuration = ServerConfiguration.launch()

  var body: some View {
    VStack(spacing: 16) {
      Text("Prioridade · teste isolado")
      Text(configuration.url.absoluteString).accessibilityIdentifier("debug-server-url")
      Text(report).accessibilityIdentifier("activity-priority-report")
      Button("Iniciar voz") { state.apply(.start); state.apply(.connected); publish() }
      Button("Reconectar") { state.apply(.reconnect); publish() }
      Button("Sem conexão") { state.apply(.offline); publish() }
      Button("Retomar") { state.apply(.connected); publish() }
      Button("Silenciar") { state.muted.toggle(); publish() }
      Button("Atualizar agentes") {
        Task {
          guard var fixture = AgentsActivityFixtures.requested?.first else { return }
          fixture.state.focus?.progress?.done = 1
          await agents.apply(fixture.state, server: configuration.url)
          snapshot()
        }
      }
      Button("Encerrar voz") { Task { await voice.end(); state.apply(.end); snapshot() } }
      Button("Ler atividades") { snapshot() }
    }
    .task {
      guard configuration.url.host == "127.0.0.1",
        let fixture = AgentsActivityFixtures.requested?.first,
        let json = try? String(data: JSONEncoder().encode(fixture.state), encoding: .utf8) else { return }
      let client = OpenCodeClient.screenCatalog(configuration: configuration, responses: [
        "/api/rpc/custom.live-activity/register": #"{"output":{"push":"unconfigured"}}"#,
        "/api/rpc/custom.live-activity/snapshot": "{\"output\":{\"state\":\(json)}}",
        "/api/rpc/custom.live-activity/activity": #"{"output":{}}"#,
        "/api/rpc/custom.live-activity/ended": #"{"output":{}}"#,
      ])
      await agents.begin(nil)
      await agents.connect(.init(client: client, serverKey: fixture.attributes.serverKey,
        deviceID: "priority-fixture", environment: .sandbox), theme: fixture.attributes.theme)
      snapshot()
    }
  }

  private func publish() {
    voice.update(id: id, state: state, theme: .selected) { action in
      switch action {
      case .mute: state.muted.toggle(); publish()
      case .end: await voice.end(); state.apply(.end); snapshot()
      }
    }
  }

  private func snapshot() {
    let calls = Activity<VoiceActivityAttributes>.activities.filter { $0.activityState == .active }
    let work = Activity<AgentsActivityAttributes>.activities.filter { $0.activityState == .active }
    report = (calls.map { "voz=\(Int($0.content.relevanceScore)) \($0.content.state.label)" }
      + work.map { "agentes=\(Int($0.content.relevanceScore)) id=\($0.id) progresso=\($0.content.state.focus?.progress?.done ?? -1)" })
      .joined(separator: "\n")
  }
}
#endif
