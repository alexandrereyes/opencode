import OpenCodeKit
import SwiftUI
import WidgetKit

/// Both complications are offered in the face's gallery; Alexandre places them himself.
@main
struct OpenCodeWatchWidgets: WidgetBundle {
  var body: some Widget {
    AgentsComplication()
    VoiceShortcutComplication()
  }
}

/// The attention complication (rev. 2026-11-01): the kinds of priority attention waiting, never a count (see
/// `WatchAttention`). The timeline reads `/watch/v1/state` (as `widget`), keeps the last good state in the shared
/// Keychain group and reloads on WidgetKit push (the server pushes only a kind appearing or clearing), when the app's
/// background refresh sees one, and otherwise every hour. Every one of those reloads counts against the WidgetKit
/// budget. Tapping opens the app on the Painel.
struct AgentsComplication: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchShared.widgetKind, provider: AgentsProvider()) { entry in
      AgentsComplicationView(entry: entry)
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(WatchLaunch.dashboard.url)
    }
    .configurationDisplayName("OpenCode")
    .description("Pergunta, permissão ou erro esperando por você.")
    .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
    .pushHandler(AgentsPushHandler.self)
  }
}

/// "Falar" (rev. 2026-11-01): a static microphone. It reads no state and has no push handler, and its only entry
/// never expires, so it spends nothing of the WidgetKit budget. Tapping opens Voz, which starts a call on the watch.
struct VoiceShortcutComplication: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchShared.voiceWidgetKind, provider: VoiceShortcutProvider()) { _ in
      VoiceShortcutView()
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(WatchLaunch.voice.url)
    }
    .configurationDisplayName("Falar")
    .description("Começa a conversa por voz com a Sessão mestra no relógio.")
    .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular])
  }
}

struct VoiceShortcutEntry: TimelineEntry {
  let date: Date
}

struct VoiceShortcutProvider: TimelineProvider {
  func placeholder(in context: Context) -> VoiceShortcutEntry { VoiceShortcutEntry(date: Date()) }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (VoiceShortcutEntry) -> Void) {
    completion(VoiceShortcutEntry(date: Date()))
  }

  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<VoiceShortcutEntry>) -> Void) {
    completion(Timeline(entries: [VoiceShortcutEntry(date: Date())], policy: .never))
  }
}

struct VoiceShortcutView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .accessoryCorner: VoiceComplicationCorner()
    case .accessoryRectangular: VoiceComplicationRectangular()
    default: VoiceComplicationCircular()
    }
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
      let now = Date()
      let entry = await Self.load(now: now)
      // A second entry turns `agora` into the relative age after a minute, without a reload.
      let entries = WatchAge.entryDates(fetched: entry.fetched, now: now).map {
        AgentsEntry(date: $0, state: entry.state, fetched: entry.fetched)
      }
      completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(WatchAge.timelineReload))))
    }
  }

  /// Fresh state when the Mac answers; otherwise the last good one (or nothing once unpaired).
  static func load(now: Date) async -> AgentsEntry {
    let cache = WatchStateCache()
    guard let pairing = try? WatchKeychain().read() else {
      cache.write(nil)
      return AgentsEntry(date: now, state: nil, fetched: nil)
    }
    let client = WatchGatewayClient(pairing: pairing, version: version, reader: .widget)
    switch await WatchStateSync(client: client, cache: cache).run(now: now) {
    case .fetched(let entry, _, _): return AgentsEntry(date: now, state: entry.snapshot.state, fetched: entry.fetched)
    case .unreachable(let cached): return AgentsEntry(date: now, state: cached?.snapshot.state, fetched: cached?.fetched)
    case .unauthorized:
      let cached = cache.read()
      return AgentsEntry(date: now, state: cached?.snapshot.state, fetched: cached?.fetched)
    }
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
    case .accessoryRectangular: ComplicationRectangular(state: entry.state, fetched: entry.fetched, now: entry.date)
    default: ComplicationCircular(state: entry.state)
    }
  }
}
