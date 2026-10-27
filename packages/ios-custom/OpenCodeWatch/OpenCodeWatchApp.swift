import OpenCodeKit
import SwiftUI

@main
struct OpenCodeWatchApp: App {
  @State private var model: WatchModel
  @State private var voice: VoiceCall
  @State private var link: WatchLink

  init() {
    let fixture = WatchFixture.launch
    let model = WatchModel(fixture: fixture)
    let voice = VoiceCall(fixture: fixture != nil)
    if fixture?.screen == .voice { voice.showFixture() }
    let link = WatchLink(model: model)
    if fixture == nil { link.activate() }
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
      ComplicationsPreview(entry: model.entry)
    default:
      DashboardView(model: model, voice: voice)
    }
  }
}

/// DEBUG capture of the three complication families at their device sizes (Ultra 49 mm).
private struct ComplicationsPreview: View {
  let entry: WatchStateCache.Entry?
  var body: some View {
    ScrollView {
      VStack(spacing: 10) {
        HStack(spacing: 14) {
          ComplicationCircular(state: entry?.snapshot.state).frame(width: 58, height: 58)
          ComplicationCircular(state: nil).frame(width: 58, height: 58)
        }
        ComplicationRectangular(state: entry?.snapshot.state)
          .frame(width: 180, height: 66).padding(6)
          .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        Text(entry?.snapshot.state?.complicationLine ?? "").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}
