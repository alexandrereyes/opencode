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

/// Receives the WidgetKit push token (it needs `aps-environment` in this extension's entitlements; without it
/// WidgetKit never issues one). The token is saved in the shared Keychain first, then sent when paired; the watch app
/// sends whatever is still pending. The backend sends `content-changed` pushes.
struct AgentsPushHandler: WidgetPushHandler {
  func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
    let token = pushInfo.token
    Task {
      await WatchWidgetToken(version: AgentsProvider.version).sync(token: token, environment: WatchEnvironment.push,
        pairing: try? WatchKeychain().read())
    }
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
