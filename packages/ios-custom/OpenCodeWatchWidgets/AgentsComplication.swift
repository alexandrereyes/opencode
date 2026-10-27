import OpenCodeKit
import SwiftUI
import WidgetKit

@main
struct OpenCodeWatchWidgets: WidgetBundle {
  var body: some Widget { AgentsComplication() }
}

/// Complications (`opcao-1-anel-estados.png`): the ring, the corner count and one rectangular line. The
/// timeline reads `/watch/v1/state`, keeps the last good state in the shared Keychain group and refreshes on WidgetKit push
/// and about every 15 minutes. Tapping opens the app on the dashboard.
struct AgentsComplication: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchShared.widgetKind, provider: AgentsProvider()) { entry in
      AgentsComplicationView(entry: entry)
        .containerBackground(for: .widget) { Color.clear }
    }
    .configurationDisplayName("OpenCode")
    .description("Sessões ativas e o que precisa de você.")
    .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    .pushHandler(AgentsPushHandler.self)
  }
}

struct AgentsEntry: TimelineEntry {
  let date: Date
  let state: AgentsState?
  let fetched: Date?
}

struct AgentsProvider: TimelineProvider {
  func placeholder(in context: Context) -> AgentsEntry { AgentsEntry(date: Date(), state: nil, fetched: nil) }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (AgentsEntry) -> Void) {
    let cached = WatchStateCache().read()
    completion(AgentsEntry(date: Date(), state: cached?.snapshot.state, fetched: cached?.fetched))
  }

  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<AgentsEntry>) -> Void) {
    Task {
      let entry = await Self.load()
      completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
  }

  /// Fresh state when the Mac answers; otherwise the last good one (or nothing once unpaired).
  static func load() async -> AgentsEntry {
    let cache = WatchStateCache()
    guard let pairing = try? WatchKeychain().read() else {
      cache.write(nil)
      return AgentsEntry(date: Date(), state: nil, fetched: nil)
    }
    let client = WatchGatewayClient(pairing: pairing, version: version)
    if let snapshot = try? await client.state() {
      let entry = WatchStateCache.Entry(snapshot: snapshot, fetched: Date())
      cache.write(entry)
      return AgentsEntry(date: Date(), state: snapshot.state, fetched: entry.fetched)
    }
    let cached = cache.read()
    return AgentsEntry(date: Date(), state: cached?.snapshot.state, fetched: cached?.fetched)
  }

  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
}

/// Registers the WidgetKit push token with the gateway; the backend sends `content-changed` pushes.
struct AgentsPushHandler: WidgetPushHandler {
  func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
    let token = pushInfo.token
    Task {
      guard let pairing = try? WatchKeychain().read() else { return }
      try? await WatchGatewayClient(pairing: pairing, version: AgentsProvider.version)
        .widgetToken(token, environment: Self.environment)
    }
  }

  static var environment: PushEnvironment {
    #if targetEnvironment(simulator)
      PushEnvironment.resolve(profile: nil, simulator: true)
    #else
      PushEnvironment.resolve(
        profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
          .flatMap { try? Data(contentsOf: $0) }, simulator: false)
    #endif
  }
}

struct AgentsComplicationView: View {
  @Environment(\.widgetFamily) private var family
  let entry: AgentsEntry

  var body: some View {
    switch family {
    case .accessoryCorner: ComplicationCorner(state: entry.state)
    case .accessoryRectangular: ComplicationRectangular(state: entry.state)
    default: ComplicationCircular(state: entry.state)
    }
  }
}
