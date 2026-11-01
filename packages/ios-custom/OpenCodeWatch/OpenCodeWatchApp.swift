import OpenCodeKit
import SwiftUI
import WatchConnectivity
import WatchKit
import os

@main
struct OpenCodeWatchApp: App {
  @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
  @State private var model: WatchModel
  @State private var voice: VoiceCall
  @State private var link: WatchLink

  init() {
    let fixture = WatchFixture.launch
    let model = WatchModel(fixture: fixture)
    let voice = VoiceCall(fixture: fixture != nil)
    if fixture?.screen == .voice || (fixture != nil && WatchFixture.voiceLive) { voice.showFixture() }
    let link = WatchLink(model: model)
    if fixture == nil {
      link.activate()
      WatchAppDelegate.model = model
    }
    _model = State(initialValue: model)
    _voice = State(initialValue: voice)
    _link = State(initialValue: link)
  }

  var body: some Scene {
    WindowGroup {
      root.preferredColorScheme(.dark).tint(Color.watch(.primary))
    }
  }

  @ViewBuilder private var root: some View {
    switch WatchFixture.launch?.screen {
    case .question?, .permission?:
      let kind: AgentsState.Kind = WatchFixture.launch?.screen == .permission ? .permission : .question
      let request = kind == .permission ? WatchFixture.permission : WatchFixture.question
      NavigationStack {
        ReplyView(model: model, route: ReplyRoute(attention: try! JSONDecoder().decode(AgentsState.Attention.self,
          from: Data("""
            {"sessionID":"s","title":"\(request.title)","project":"\(request.project)","directory":"/r",
             "kind":"\(kind.rawValue)","since":\(request.asked.timeIntervalSince1970 * 1000),
             "requestID":"\(request.requestID)"}
            """.utf8))))
      }
    case .voice?:
      NavigationStack { VoiceView(call: voice, pairing: nil) }
    case .complications?:
      ComplicationsPreview(entry: model.entry, voice: false)
    case .complicationsVoice?:
      ComplicationsPreview(entry: nil, voice: true)
    default:
      DashboardView(model: model, voice: voice)
    }
  }
}

/// Receives the background tasks. watchOS refuses `scheduleBackgroundRefresh` (it crashes the app) unless the
/// application delegate implements `handle(_:)`, and then every task comes here, including WatchConnectivity's.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  /// The app's model, set at launch; nil for DEBUG fixtures, which never refresh.
  @MainActor static var model: WatchModel?

  func applicationDidFinishLaunching() {
    if Self.model != nil { BackgroundRefresh.schedule() }
  }

  /// A refresh due while the app is in front is dropped by the system, so leaving it schedules the next one.
  func applicationDidEnterBackground() {
    if Self.model != nil { BackgroundRefresh.schedule() }
  }

  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refresh as WKApplicationRefreshBackgroundTask:
        guard let model = Self.model else {
          refresh.setTaskCompletedWithSnapshot(false)
          continue
        }
        Task { @MainActor in
          await model.refreshInBackground()
          BackgroundRefresh.schedule()
          refresh.setTaskCompletedWithSnapshot(false)
        }
      case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
        // A pairing sent while the app was not running: completing at once could cut its delivery.
        Task { @MainActor in
          for _ in 0..<20 where WCSession.default.hasContentPending { try? await Task.sleep(for: .milliseconds(250)) }
          connectivity.setTaskCompletedWithSnapshot(false)
        }
      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }
}

/// Background app refresh (`WatchBackgroundRefresh`): about every 30 minutes, rescheduled after each run and
/// whenever the app leaves the screen (only one can be pending; a new one replaces it).
enum BackgroundRefresh {
  static let log = Logger(subsystem: "br.com.alexandrem.opencode.watchkitapp", category: "BackgroundRefresh")

  @MainActor static func schedule() {
    let date = WatchBackgroundRefresh.next(after: .now, interval: interval)
    WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date,
      userInfo: WatchBackgroundRefresh.identifier as NSString)
    { error in
      if let error { log.error("schedule: \(error.localizedDescription, privacy: .public)") }
    }
    log.notice("scheduled for \(date.formatted(.iso8601), privacy: .public)")
  }

  /// `-OpenCodeWatchRefreshSeconds N` shortens it in DEBUG builds, to watch a refresh happen in the simulator.
  private static var interval: TimeInterval {
    #if DEBUG
      let seconds = UserDefaults.standard.double(forKey: "OpenCodeWatchRefreshSeconds")
      if seconds > 0 { return seconds }
    #endif
    return WatchBackgroundRefresh.interval
  }
}

/// DEBUG capture of the three complication families at their device sizes (Ultra 49 mm): the attention complication
/// for the fixture's state (`-OpenCodeWatchCombo`), or "Falar". The corner's curved label only draws on a watch face,
/// so it is written below its circle; the last line is what VoiceOver reads.
private struct ComplicationsPreview: View {
  let entry: WatchStateCache.Entry?
  let voice: Bool

  var body: some View {
    let attention = WatchAttention(entry?.snapshot.state)
    ScrollView {
      VStack(spacing: 10) {
        HStack(spacing: 18) {
          Group {
            if voice { VoiceComplicationCircular() } else { ComplicationCircular(state: entry?.snapshot.state) }
          }
          .frame(width: 58, height: 58)
          VStack(spacing: 3) {
            Group {
              if voice { VoiceComplicationCorner() } else { ComplicationCorner(state: entry?.snapshot.state) }
            }
            .frame(width: 40, height: 40)
            Text(voice ? "Falar" : attention.cornerLabel).font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.watch(voice ? .primary : attention.top?.role ?? .textSecondary))
          }
        }
        TimelineView(.periodic(from: entry?.fetched ?? .now, by: WatchAge.fresh)) { context in
          Group {
            if voice {
              VoiceComplicationRectangular()
            } else {
              ComplicationRectangular(state: entry?.snapshot.state, fetched: entry?.fetched, now: context.date)
            }
          }
          .frame(width: 180, height: 66).padding(6)
          .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        }
        Text(voice ? VoiceComplicationCircular.label : attention.accessibilityLabel).font(.caption2)
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
    }
  }
}
