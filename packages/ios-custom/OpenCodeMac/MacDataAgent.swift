import AppKit
import Observation
import OpenCodeKit
import SystemConfiguration
import os

/// Answers the agents' `mac_query` while the app runs, like the iPhone's `DeviceAgent`: it keeps a presence lease on
/// the connected server through `custom.mac/attach` and answers `rpc.custom.mac.request` events with
/// `MacDataCollectors`, under this app's own Calendar, Reminders and Contacts grants.
@MainActor @Observable final class MacDataAgent {
  static let shared = MacDataAgent()
  static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "MacData")
  /// Only the installed app answers, so development and fixture runs never compete with it for requests.
  /// `-OpenCodeMacData` lets a development build answer too.
  static let active = !MacLaunch.fixture
    && (Bundle.main.bundleIdentifier == "br.com.alexandrem.opencode.mac"
      || ProcessInfo.processInfo.arguments.contains("-OpenCodeMacData"))
  @ObservationIgnored let preferences = MacDataPreferences()
  @ObservationIgnored let collectors = MacDataCollectors()
  private(set) var enabled: Set<MacDataSource>
  private(set) var permissions: [MacDataSource: MacDataPermission] = [:]
  private(set) var answered: [MacDataSource: Date] = [:]
  private(set) var connected = false
  @ObservationIgnored private var client: OpenCodeClient?
  @ObservationIgnored private var heartbeat: Task<Void, Never>?

  private init() {
    enabled = preferences.enabledSources
    answered = Dictionary(uniqueKeysWithValues: MacDataSource.allCases.compactMap { source in
      preferences.lastAnswered(source).map { (source, $0) }
    })
    refreshPermissions()
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
      queue: .main) { _ in MainActor.assumeIsolated { MacDataAgent.shared.refreshPermissions() } }
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
      queue: .main) { _ in MainActor.assumeIsolated { MacDataAgent.shared.detachBeforeQuitting() } }
  }

  /// Quitting does not end the event stream gracefully; without this the server would keep sending requests to a
  /// closed app until its lease expires, and each one would wait for the whole timeout.
  private func detachBeforeQuitting() {
    guard connected, let client else { return }
    let deviceID = preferences.deviceID
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      try? await client.macDetach(deviceID: deviceID)
      done.signal()
    }
    _ = done.wait(timeout: .now() + 1)
  }

  func refreshPermissions() {
    for source in MacDataSource.allCases { permissions[source] = MacDataCollectors.permission(source) }
  }

  func setEnabled(_ source: MacDataSource, _ value: Bool) async {
    preferences.set(source, enabled: value)
    enabled = preferences.enabledSources
    if value { await requestPermission(source) }
  }

  /// Shows the macOS prompt when it was never answered; Alexandre has a minute to answer it.
  func requestPermission(_ source: MacDataSource) async {
    _ = await collectors.authorize(source, until: .now.addingTimeInterval(60))
    refreshPermissions()
  }

  // MARK: Event stream

  func connected(_ client: OpenCodeClient) {
    guard Self.active else { return }
    self.client = client
    connected = true
    heartbeat?.cancel()
    heartbeat = Task {
      while !Task.isCancelled {
        await attach(client)
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }

  /// `stopped` is true when the event stream ended for good (the app switched servers or quit).
  func disconnected(stopped: Bool) {
    heartbeat?.cancel()
    heartbeat = nil
    connected = false
    guard stopped, let client else { return }
    let deviceID = preferences.deviceID
    Task { try? await client.macDetach(deviceID: deviceID) }
  }

  func receive(_ event: ConversationEvent, client: OpenCodeClient) {
    guard Self.active, let request = MacDataRequest.decode(event), request.deviceID == preferences.deviceID else {
      return
    }
    let collectors = collectors
    let status = statusAnswer()
    Task {
      let answer = await MacDataDispatcher.answer(request, enabled: enabled) { query, deadline in
        if query.source == .status { return status }
        return try await collectors.collect(query, until: deadline)
      }
      refreshPermissions()
      let failed = if case .object(let fields) = answer { fields["error"] != nil } else { true }
      Self.log.notice("mac request source=\(request.query.source.rawValue, privacy: .public) ok=\(!failed)")
      if !failed, let source = request.query.dataSource {
        preferences.answered(source)
        answered[source] = .now
      }
      do { try await client.macRespond(request, answer: answer) } catch {
        Self.log.error("mac respond failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func statusAnswer() -> JSONValue {
    refreshPermissions()
    let sources = MacDataSource.allCases
    return .object([
      "source": .string("status"),
      "permissions": .object(Dictionary(uniqueKeysWithValues: sources.map {
        ($0.rawValue, JSONValue.string((permissions[$0] ?? .notDetermined).rawValue))
      })),
      "enabled": .object(Dictionary(uniqueKeysWithValues: sources.map { ($0.rawValue, JSONValue.bool(enabled.contains($0))) })),
    ])
  }

  private func attach(_ client: OpenCodeClient) async {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    do {
      try await client.macAttach(MacDataAttach(deviceID: preferences.deviceID,
        name: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac", model: Self.model,
        system: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"))
    } catch { Self.log.debug("mac attach failed: \(error.localizedDescription, privacy: .public)") }
  }

  private static let model: String? = {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }()
}
