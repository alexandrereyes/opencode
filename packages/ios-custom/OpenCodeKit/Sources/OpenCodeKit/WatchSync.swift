import Foundation

/// What the complication draws from a state: the ring's counts and the two totals. A background refresh reloads the
/// complication only when this changes, because WidgetKit counts those reloads against a daily budget (40 to 70 for
/// a widget looked at often). Mirrors the plugin's `watch/widget.ts` key.
public struct WatchComplicationKey: Equatable, Sendable {
  let counts: AgentsState.Counts?
  let active: Int
  let attention: Int

  public init(_ state: AgentsState?) {
    counts = state?.counts
    active = state?.activeTotal ?? 0
    attention = state?.attentionTotal ?? 0
  }
}

/// One read of `/watch/v1/state` into the shared cache, the same for the app in front, its background refresh and
/// the complication's own timeline.
public struct WatchStateSync: Sendable {
  public enum Result: Equatable, Sendable {
    /// `changed`: anything differs from the previous cache; `redraw`: what the complication draws differs.
    case fetched(WatchStateCache.Entry, changed: Bool, redraw: Bool)
    /// The gateway rejected the device token: pair again from the iPhone.
    case unauthorized
    /// No answer from the Mac; the cache is untouched.
    case unreachable(cached: WatchStateCache.Entry?)
  }

  private let read: @Sendable () -> WatchStateCache.Entry?
  private let write: @Sendable (WatchStateCache.Entry) -> Void
  private let fetch: @Sendable () async throws -> WatchStateSnapshot

  public init(client: WatchGatewayClient, cache: WatchStateCache = WatchStateCache(), timeout: TimeInterval = 15) {
    self.init(read: { cache.read() }, write: { cache.write($0) }, fetch: { try await client.state(timeout: timeout) })
  }

  public init(read: @escaping @Sendable () -> WatchStateCache.Entry?,
    write: @escaping @Sendable (WatchStateCache.Entry) -> Void,
    fetch: @escaping @Sendable () async throws -> WatchStateSnapshot)
  {
    self.read = read
    self.write = write
    self.fetch = fetch
  }

  public func run(now: Date = .now) async -> Result {
    let previous = read()
    let snapshot: WatchStateSnapshot
    do {
      snapshot = try await fetch()
    } catch WatchGatewayError.unauthorized {
      return .unauthorized
    } catch {
      return .unreachable(cached: previous)
    }
    let entry = WatchStateCache.Entry(snapshot: snapshot, fetched: now)
    write(entry)
    return .fetched(entry, changed: snapshot != previous?.snapshot,
      redraw: previous == nil || WatchComplicationKey(snapshot.state) != WatchComplicationKey(previous?.snapshot.state))
  }
}

/// Background app refresh of the watch app (`WKApplication.scheduleBackgroundRefresh`): about every 30 minutes it
/// reads the state into the cache and reloads the complication only when what it draws changed. The server folds
/// routine changes into one WidgetKit push per 30 minutes too, and skips states the watch already read, so the two
/// together spend about two budgeted reloads an hour on routine changes.
public enum WatchBackgroundRefresh {
  /// `userInfo` of the scheduled task.
  public static let identifier = "br.com.alexandrem.opencode.watch.state"
  public static let interval: TimeInterval = 30 * 60
  /// watchOS gives a background task a few seconds; the read gives up before that.
  public static let timeout: TimeInterval = 8

  public static func next(after now: Date, interval: TimeInterval = interval) -> Date {
    now.addingTimeInterval(max(interval, 1))
  }
}

/// The age of the state shown by the Painel and the rectangular complication: `agora` during its first minute,
/// then the system's live relative text (`há 3 min.`).
public enum WatchAge {
  public static let fresh: TimeInterval = 60
  /// The complication's timeline policy: a fallback, since pushes and the background refresh reload it when needed.
  public static let timelineReload: TimeInterval = 60 * 60

  public static func isFresh(_ fetched: Date, at now: Date) -> Bool { now.timeIntervalSince(fetched) < fresh }

  /// Timeline entry dates for state fetched at `fetched`: now, plus the moment `agora` turns into the relative text
  /// (entries cost no reload).
  public static func entryDates(fetched: Date?, now: Date) -> [Date] {
    guard let fetched, isFresh(fetched, at: now) else { return [now] }
    return [now, fetched.addingTimeInterval(fresh)]
  }
}
