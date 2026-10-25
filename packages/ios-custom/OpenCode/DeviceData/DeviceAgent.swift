import Observation
import OpenCodeKit
import UIKit
import os

/// Answers the agents' `iphone_query` while the app runs: it keeps a presence lease on the connected
/// server through `custom.device/attach` and answers `rpc.custom.device.request` events with the local collectors.
@MainActor @Observable final class DeviceAgent {
  static let shared = DeviceAgent()
  static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "DeviceData")
  @ObservationIgnored let preferences = DevicePreferences()
  @ObservationIgnored let collectors = DeviceCollectors()
  private(set) var enabled: Set<DeviceSource>
  private(set) var authorizations: [DeviceSource: DeviceAuthorization] = [:]
  private(set) var answered: [DeviceSource: Date] = [:]
  private(set) var connected = false
  @ObservationIgnored private var client: OpenCodeClient?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?

  private init() {
    enabled = preferences.enabledSources
    answered = Dictionary(uniqueKeysWithValues: DeviceSource.allCases.compactMap { source in
      preferences.lastAnswered(source).map { (source, $0) }
    })
  }

  func refreshAuthorizations() async {
    for source in DeviceSource.allCases { authorizations[source] = await collectors.authorization(source) }
  }

  /// Turning a source on asks for its iOS permission the first time.
  func setEnabled(_ source: DeviceSource, _ value: Bool) async {
    preferences.set(source, enabled: value)
    enabled = preferences.enabledSources
    if value { authorizations[source] = await collectors.requestAuthorization(source) }
    if value, source == .health { collectors.health.refreshCache(force: true) }
    if connected, let client { await attach(client) }
  }

  func sceneBecameActive() {
    Task {
      await refreshAuthorizations()
      if enabled.contains(.health), authorizations[.health]?.usable == true { collectors.health.refreshCache(force: false) }
    }
  }

  // MARK: Event stream

  func connected(_ client: OpenCodeClient) {
    self.client = client
    connected = true
    heartbeat?.cancel()
    heartbeat = Task {
      if authorizations.isEmpty { await refreshAuthorizations() }
      while !Task.isCancelled {
        await attach(client)
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }

  /// `stopped` is true when the event stream ended for good (the app left the foreground with no voice call).
  func disconnected(stopped: Bool) {
    heartbeat?.cancel()
    heartbeat = nil
    connected = false
    guard stopped, let client else { return }
    let deviceID = preferences.deviceID
    Task { try? await client.deviceDetach(deviceID: deviceID) }
  }

  func receive(_ event: ConversationEvent, client: OpenCodeClient) {
    guard let request = DeviceRequest.decode(event), request.deviceID == preferences.deviceID else { return }
    let enabled = enabled
    let collectors = collectors
    Task {
      let answer = await DeviceDispatcher.answer(request, enabled: enabled) { query in await collectors.collect(query) }
      Self.log.notice("device request source=\(request.query.source.rawValue, privacy: .public) status=\(answer.status.rawValue, privacy: .public)")
      if answer.status == .ok {
        preferences.answered(request.query.source)
        answered[request.query.source] = .now
      }
      do { try await client.deviceRespond(request, answer: answer) } catch {
        Self.log.error("device respond failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  #if DEBUG
  /// `-OpenCodeDeviceProbe` enables every source (showing the iOS prompts), collects each once and writes
  /// `Documents/device-probe.json`, for physical-device checks without a reachable server.
  func probeIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains("-OpenCodeDeviceProbe") else { return }
    Task {
      var results: [String: DeviceAnswer] = [:]
      for source in DeviceSource.allCases {
        await setEnabled(source, true)
        let query = DeviceQuery(source: source, granularity: source == .health ? .sample : nil,
          limit: source == .photos ? 3 : nil)
        var answer = await collectors.collect(query)
        answer.files = answer.files?.map { DeviceFile(name: $0.name, mime: $0.mime, data: "\($0.data.count) base64 chars") }
        results[source.rawValue] = answer
      }
      collectors.health.refreshCache(force: true)
      try? await Task.sleep(for: .seconds(8))
      results["healthLocked"] = collectors.health.cachedAnswer(DeviceQuery(source: .health))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let url = URL.documentsDirectory.appending(path: "device-probe.json")
      do {
        try encoder.encode(results).write(to: url, options: .atomic)
        Self.log.notice("device probe written: \(url.path, privacy: .public)")
      } catch { Self.log.error("device probe failed: \(error.localizedDescription, privacy: .public)") }
    }
  }
  #endif

  private func attach(_ client: OpenCodeClient) async {
    let sources = DeviceSource.allCases.map { source in
      DeviceSourceState(source: source, enabled: enabled.contains(source),
        authorization: authorizations[source] ?? .notDetermined)
    }
    do {
      try await client.deviceAttach(DeviceAttach(deviceID: preferences.deviceID, name: UIDevice.current.name,
        model: DeviceCollectors.modelIdentifier, system: "iOS " + UIDevice.current.systemVersion, sources: sources))
    } catch { Self.log.debug("device attach failed: \(error.localizedDescription, privacy: .public)") }
  }
}
