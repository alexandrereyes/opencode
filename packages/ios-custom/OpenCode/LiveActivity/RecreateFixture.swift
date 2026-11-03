#if DEBUG
import ActivityKit
import OpenCodeKit
import SwiftUI

/// `-OpenCodeAgentsActivityFixture <state> -OpenCodeRecreateFixture` (with `-OpenCodeRecreateFail register` to refuse
/// the new activity's registration): the real "Recriar Live Activity" section and agents driver with ActivityKit,
/// against a closed in-memory `custom.live-activity` that records every call, plus a voice activity that must
/// survive. No APNs, no server, no audio.
struct RecreateFixtureRoot: View {
  private let agents = AgentsActivityAgent.shared.fixtureDriver
  @State private var voice = VoiceActivityDriver()
  @State private var report = "Preparando"
  private let calls = RecreateFixtureCalls(failRegister: Self.value("-OpenCodeRecreateFail") == "register")
  private let configuration = ServerConfiguration.launch()
  private let timeout = Double(Self.value("-OpenCodeRecreateTimeout") ?? "") ?? 30

  var body: some View {
    NavigationStack {
      List {
        AgentsRecreateSection(recreate: {
          let outcome = await agents.recreate(timeout: .seconds(timeout))
          snapshot()
          return outcome
        }, cancel: { Task { await agents.cancelRecreation() } })
        Section("Teste isolado") {
          Text(configuration.url.absoluteString).accessibilityIdentifier("debug-server-url")
          Text(report).font(.caption.monospaced()).accessibilityIdentifier("recreate-report")
          Button("Ler atividades") { snapshot() }
        }
      }
      .navigationTitle("Apple Watch").navigationBarTitleDisplayMode(.inline)
    }
    .task {
      guard configuration.url.host == "127.0.0.1", let fixture = AgentsActivityFixtures.requested?.first,
        let json = try? String(data: JSONEncoder().encode(fixture.state), encoding: .utf8) else { return }
      let calls = calls
      let client = OpenCodeClient.inMemory(configuration: configuration) { request in
        calls.answer(request, snapshot: json)
      }
      var state = VoiceState()
      state.apply(.start)
      state.apply(.connected)
      voice.update(id: UUID(), state: state, theme: .selected) { _ in }
      await agents.begin(nil)
      await agents.connect(.init(client: client, serverKey: fixture.attributes.serverKey,
        deviceID: "recreate-fixture", environment: .sandbox), theme: fixture.attributes.theme)
      snapshot()
    }
  }

  /// `agentes=1 [id:active:token] voz=1` then the recorded calls, one per line.
  private func snapshot() {
    let work = Activity<AgentsActivityAttributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    let calls = Activity<VoiceActivityAttributes>.activities.filter { $0.activityState == .active }
    report = (["agentes=\(work.count) " + work.map { "[\(Self.short($0.id)):\($0.pushToken == nil ? "sem-token" : "token")]" }
      .joined(separator: " ") + " voz=\(calls.count)"] + self.calls.lines).joined(separator: "\n")
  }

  nonisolated static func short(_ id: String) -> String { String(id.prefix(8)) }

  private static func value(_ key: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}

/// The in-memory `custom.live-activity`: answers like the server and keeps the calls in order.
final class RecreateFixtureCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var log: [String] = []
  private var first: String?
  private let failRegister: Bool

  init(failRegister: Bool) { self.failRegister = failRegister }

  var lines: [String] { lock.withLock { log } }

  func answer(_ request: URLRequest, snapshot: String) -> String? {
    let method = request.url?.lastPathComponent ?? ""
    let input = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["input"]
      as? [String: Any]
    let activity = (input?["activityID"] as? String).map(RecreateFixtureRoot.short)
    return lock.withLock {
      switch method {
      case "register":
        log.append("register")
        return #"{"output":{"push":"unconfigured"}}"#
      case "snapshot":
        return "{\"output\":{\"state\":\(snapshot)}}"
      case "activity":
        if first == nil { first = activity }
        // Refuses every registration but the first activity's, like a server that stopped answering mid-swap.
        guard !failRegister || activity == first else {
          log.append("activity \(activity ?? "?") recusada")
          return nil
        }
        log.append("activity \(activity ?? "?")")
        return #"{"output":{}}"#
      case "ended":
        log.append("ended \(activity ?? "?") \(input?["reason"] as? String ?? "?")")
        return #"{"output":{}}"#
      default:
        log.append(method)
        return nil
      }
    }
  }
}
#endif
