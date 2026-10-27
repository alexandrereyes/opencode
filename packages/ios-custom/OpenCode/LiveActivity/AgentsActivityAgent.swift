import ActivityKit
import OpenCodeKit
import SwiftUI
import os

/// Main-actor entry point of the "Agentes" Live Activity: it gathers the device ID, server key, APNs environment
/// and theme snapshot, and forwards connections and `changed` events to `AgentsActivityDriver`, which does the
/// ActivityKit and RPC work off the main actor. Contract: `plugin-app-custom/docs/live-activity.md`.
@MainActor final class AgentsActivityAgent {
  static let shared = AgentsActivityAgent()
  nonisolated static let log = Logger(subsystem: "br.com.alexandrem.opencode", category: "AgentsActivity")
  private let driver = AgentsActivityDriver()
  private var theme = AgentsTheme.snapshot(AppTheme.selected.value)
  private var started = false
  #if DEBUG
  private let fixture = AgentsActivityFixtures.requested != nil
  #else
  private let fixture = false
  #endif

  /// Xcode builds carry a development profile (APNs sandbox); TestFlight builds have none (production).
  let environment: PushEnvironment = {
    #if targetEnvironment(simulator)
    let simulator = true
    #else
    let simulator = false
    #endif
    let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
      .flatMap { try? Data(contentsOf: $0) }
    return PushEnvironment.resolve(profile: profile, simulator: simulator)
  }()

  /// Called once at launch: watches push-to-start tokens and every activity, including ones started by push.
  func start() {
    guard !started else { return }
    started = true
    Task { await driver.begin() }
    #if DEBUG
    if let fixtures = AgentsActivityFixtures.requested { Task { await driver.show(fixtures) } }
    #endif
  }

  func setTheme(_ theme: AppTheme) {
    let snapshot = AgentsTheme.snapshot(theme.value)
    guard snapshot != self.theme else { return }
    self.theme = snapshot
    Task { await driver.update(theme: snapshot) }
  }

  /// Every event-stream (re)connection, which includes launch and each return to the foreground. Only the real
  /// app root starts the agent, so the screen fixtures' stores never register.
  func connected(_ client: OpenCodeClient) {
    guard started, !fixture else { return }
    let context = AgentsActivityDriver.Context(client: client, serverKey: Self.serverKey(AppRuntime.shared.servers),
      deviceID: DeviceAgent.shared.preferences.deviceID, environment: environment)
    let theme = theme
    Task { await driver.connect(context, theme: theme) }
  }

  func receive(_ event: ConversationEvent, client: OpenCodeClient) {
    guard started, !fixture, let change = AgentsChange.decode(event) else { return }
    let server = client.configuration.url
    Task { await driver.apply(change.state, server: server) }
  }

  /// Stable per configured server. The built-in entry replaced by a launch override (sandbox runs) gets its own key
  /// so it never adopts the activity of the real server.
  static func serverKey(_ servers: ServerStore) -> String { key(servers.active, servers) }

  static func server(for key: String, in servers: ServerStore) -> SavedServer? {
    servers.servers.first { Self.key($0, servers) == key }
  }

  private static func key(_ server: SavedServer, _ servers: ServerStore) -> String {
    guard server.builtIn, let url = servers.launchOverride?.url else { return server.id }
    return String("launch-\(url.host() ?? "local")-\(url.port ?? 80)".prefix(100))
  }
}

extension AppRuntime {
  /// Opens a Live Activity link: switches to its server when another one is active, then shows the session (its
  /// conversation resolves the Location from the Session) or the Sessões list.
  func open(_ link: AgentsDeepLink) async {
    if let server = AgentsActivityAgent.server(for: link.serverKey, in: servers), server.id != servers.activeID {
      do { try servers.select(server.id) } catch {
        AgentsActivityAgent.log.error("deep link server: \(error.localizedDescription, privacy: .public)")
        return
      }
    }
    guard let store = await prepare() else { return }
    store.selectedTab = 3
    switch link {
    case .session(_, let sessionID, _):
      if store.conversationPath.last?.id != sessionID { store.conversationPath = [.init(id: sessionID)] }
    case .sessions: store.conversationPath = []
    }
  }
}

/// ActivityKit and `custom.live-activity` calls, serialized off the main actor.
actor AgentsActivityDriver {
  struct Context: Sendable {
    let client: OpenCodeClient
    let serverKey: String
    let deviceID: String
    let environment: PushEnvironment
  }
  private typealias Attributes = AgentsActivityAttributes
  private var context: Context?
  private var theme: [String: String] = [:]
  private var supported = true
  private var begun = false
  private var pushToStartToken: String?
  /// Activity IDs in the order this process first saw them (oldest first), and their server keys.
  private var order: [String] = []
  private var keys: [String: String] = [:]
  /// Push tokens and terminal states waiting to be reported to their server.
  private var tokens: [String: String] = [:]
  private var reported: [String: String] = [:]
  private var endings: [String: AgentsEndReason] = [:]
  private var lastState: AgentsState?
  private var ending: Task<Void, Never>?
  /// Servers whose activity the user swiped away: like push-to-start, no new local start until `activeTotal`
  /// returns to 0 and rises again.
  private var dismissed: Set<String> = []

  func begin() {
    guard !begun else { return }
    begun = true
    for activity in Activity<Attributes>.activities { watch(activity) }
    Task {
      for await data in Activity<Attributes>.pushToStartTokenUpdates { await pushToStart(data.hexToken) }
    }
    Task {
      for await activity in Activity<Attributes>.activityUpdates { watch(activity) }
    }
  }

  func connect(_ context: Context, theme: [String: String]) async {
    if self.context?.serverKey != context.serverKey { lastState = nil; cancelEnding() }
    self.context = context
    self.theme = theme
    supported = true
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      // Live Activities are off for this app: stop push-to-start until they are turned back on.
      do { try await context.client.liveActivityUnregister(deviceID: context.deviceID) } catch { classify(error) }
      return
    }
    await register()
    guard supported, self.context?.serverKey == context.serverKey else { return }
    do {
      let state = try await context.client.liveActivitySnapshot()
      await apply(state, server: context.client.configuration.url)
    } catch { classify(error) }
  }

  func update(theme: [String: String]) async {
    guard theme != self.theme else { return }
    self.theme = theme
    if context != nil { await register() }
  }

  /// `snapshot` and `changed` while the app runs: start, update or schedule the end of this server's activity.
  func apply(_ state: AgentsState?, server: URL) async {
    guard let context, context.client.configuration.url == server, supported else { return }
    let live = activities(context.serverKey)
    guard let state = state ?? (lastState ?? live.last?.content.state).map(Self.settled) else {
      if !live.isEmpty { scheduleEnding(after: 0) }
      return
    }
    lastState = state
    if state.activeTotal == 0 { dismissed.remove(context.serverKey) }
    let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(15 * 60))
    if live.isEmpty {
      guard !dismissed.contains(context.serverKey), state.activeTotal > 0 || state.counts.failed > 0 else { return }
      start(Attributes(serverKey: context.serverKey, theme: theme), content: content)
    } else {
      for activity in live where activity.content.state != state { await Self.update(activity.id, content) }
    }
    if state.activeTotal == 0 && state.counts.failed == 0 {
      scheduleEnding(after: max(0, 600 - Date.now.timeIntervalSince(state.updated)))
    } else { cancelEnding() }
  }

  #if DEBUG
  /// `-OpenCodeAgentsActivityFixture`: replaces every Agents activity with local, push-less fixture activities.
  func show(_ fixtures: [(attributes: AgentsActivityAttributes, state: AgentsState)]) async {
    for activity in Activity<Attributes>.activities { await Self.end(activity.id, content: nil, policy: .immediate) }
    for fixture in fixtures {
      do {
        let activity = try Activity.request(attributes: fixture.attributes,
          content: ActivityContent(state: fixture.state, staleDate: nil), pushType: nil)
        AgentsActivityAgent.log.notice("fixture started \(fixture.attributes.serverKey, privacy: .public)")
        watch(activity)
      } catch { AgentsActivityAgent.log.error("fixture: \(error.localizedDescription, privacy: .public)") }
    }
  }
  #endif

  // MARK: Activities

  private func start(_ attributes: Attributes, content: ActivityContent<AgentsState>) {
    do {
      watch(try Activity.request(attributes: attributes, content: content, pushType: .token))
    } catch {
      AgentsActivityAgent.log.error("request: \(error.localizedDescription, privacy: .public)")
      // Without the push entitlement, still show a local-only activity.
      if let activity = try? Activity.request(attributes: attributes, content: content, pushType: nil) { watch(activity) }
    }
  }

  private func watch(_ activity: Activity<Attributes>) {
    let id = activity.id
    guard keys[id] == nil else { return }
    keys[id] = activity.attributes.serverKey
    order.append(id)
    if [.ended, .dismissed].contains(activity.activityState) {
      finished(id, activity.activityState == .dismissed ? .dismissed : .ended)
      return
    }
    Task {
      for await token in activity.pushTokenUpdates { await self.token(token.hexToken, for: id) }
    }
    Task {
      for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
        finished(id, state == .dismissed ? .dismissed : .ended)
        break
      }
    }
    Task { await removeDuplicates() }
  }

  /// A local start racing a push-to-start can leave two activities for one server: keep the newest.
  private func removeDuplicates() async {
    let live = Activity<Attributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    for key in Set(live.map(\.attributes.serverKey)) {
      let duplicates = live.filter { $0.attributes.serverKey == key }
        .sorted { (order.firstIndex(of: $0.id) ?? -1) < (order.firstIndex(of: $1.id) ?? -1) }
      for activity in duplicates.dropLast() { await Self.end(activity.id, content: nil, policy: .immediate) }
    }
  }

  private func activities(_ key: String) -> [Activity<Attributes>] {
    Activity<Attributes>.activities.filter {
      $0.attributes.serverKey == key && [.active, .stale].contains($0.activityState)
    }
  }

  private func scheduleEnding(after delay: TimeInterval) {
    guard ending == nil, let key = context?.serverKey else { return }
    ending = Task {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await end(key)
    }
  }

  private func cancelEnding() {
    ending?.cancel()
    ending = nil
  }

  /// Same as the backend's `end`: the final state, dismissed by the system 30 minutes later.
  private func end(_ key: String) async {
    ending = nil
    let dismissal = ActivityUIDismissalPolicy.after(.now.addingTimeInterval(30 * 60))
    for activity in activities(key) {
      let state = lastState ?? activity.content.state
      await Self.end(activity.id, content: ActivityContent(state: state, staleDate: nil), policy: dismissal)
    }
  }

  /// Activities are not `Sendable`: async calls look them up again outside the actor.
  private nonisolated static func update(_ id: String, _ content: ActivityContent<AgentsState>) async {
    await Activity<Attributes>.activities.first { $0.id == id }?.update(content)
  }

  private nonisolated static func end(_ id: String, content: ActivityContent<AgentsState>?,
    policy: ActivityUIDismissalPolicy) async
  {
    await Activity<Attributes>.activities.first { $0.id == id }?.end(content, dismissalPolicy: policy)
  }

  /// A null state means nothing is working, waiting or failed: show the last state with those parts cleared. It
  /// keeps `updatedAt`, the latest moment something was still active, which bounds the 10-minute end delay.
  private static func settled(_ state: AgentsState) -> AgentsState {
    var settled = state
    settled.counts = AgentsState.Counts(working: 0, question: 0, permission: 0, failed: 0, idle: state.counts.idle)
    settled.activeTotal = 0
    settled.focus = nil
    settled.attention = []
    settled.attentionTotal = 0
    settled.sessions = state.sessions.filter { $0.status == .idle }
    return settled
  }

  // MARK: Registration

  private func register() async {
    guard let context, supported else { return }
    do {
      let push = try await context.client.liveActivityRegister(AgentsRegistration(deviceID: context.deviceID,
        serverKey: context.serverKey, environment: context.environment, theme: theme,
        pushToStartToken: pushToStartToken))
      AgentsActivityAgent.log.notice("registered push=\(push.rawValue, privacy: .public)")
      await flush()
    } catch { classify(error) }
  }

  private func pushToStart(_ token: String) async {
    guard token != pushToStartToken else { return }
    pushToStartToken = token
    await register()
  }

  private func token(_ token: String, for id: String) async {
    tokens[id] = token
    await flush()
  }

  private func finished(_ id: String, _ reason: AgentsEndReason) {
    if reason == .dismissed, let key = keys[id] { dismissed.insert(key) }
    tokens[id] = nil
    endings[id] = reason
    Task { await flush() }
  }

  /// Reports what belongs to the connected server; other servers' items wait until they are active.
  private func flush() async {
    guard let context, supported else { return }
    for (id, reason) in endings where keys[id] == context.serverKey {
      do {
        try await context.client.liveActivityEnded(deviceID: context.deviceID, activityID: id, reason: reason)
        endings[id] = nil
        reported[id] = nil
      } catch { classify(error); return }
    }
    for (id, token) in tokens where keys[id] == context.serverKey && reported[id] != token {
      do {
        try await context.client.liveActivityToken(deviceID: context.deviceID, activityID: id, pushToken: token)
        reported[id] = token
      } catch { classify(error); return }
    }
  }

  /// A server without the RPC stays silent until the next connection; other failures retry on the next one.
  private func classify(_ error: any Error) {
    if AgentsSupport.unsupported(error) { supported = false }
    AgentsActivityAgent.log.debug("rpc failed: \(error.localizedDescription, privacy: .public)")
  }
}
