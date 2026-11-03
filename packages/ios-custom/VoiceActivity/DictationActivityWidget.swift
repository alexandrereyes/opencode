import ActivityKit
import OpenCodeKit
import SwiftUI
import WidgetKit

/// The composer dictation outside the app, the layout of Abacato V2's `VoiceRecordingWidget` in OpenCode's theme:
/// recording, the title, the system timer and Parar; paused, saved or transcribing, the state and the recorded time;
/// stale (`isStale`), "A gravação parou" with neither timer nor Parar. Parar uses the accent, never the red of
/// ending a call.
struct DictationActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DictationActivityAttributes.self) { context in
      let shown = DictationActivityText.render(context.state, stale: context.isStale)
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          DictationSymbol(state: context.state, size: 36)
          VStack(alignment: .leading, spacing: 0) {
            Text(shown.title).font(.headline).foregroundStyle(context.state.color(.textStrong)).lineLimit(1)
            if let body = shown.body {
              Text(body).font(.subheadline).foregroundStyle(context.state.color(.textSecondary)).lineLimit(2)
            }
          }
          Spacer(minLength: 8)
          if shown.timer, let started = context.state.started { DictationTimer(started: started, state: context.state) }
        }
        if shown.stop { DictationStopButton(id: context.attributes.id, state: context.state) }
      }
      .padding(.horizontal, 14).padding(.vertical, 12)
      .activityBackgroundTint(context.state.color(.background))
      .activitySystemActionForegroundColor(context.state.color(.textStrong))
      .widgetURL(DictationActivityText.url)
    } dynamicIsland: { context in
      let shown = DictationActivityText.render(context.state, stale: context.isStale)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { DictationSymbol(state: context.state, size: 36) }
        DynamicIslandExpandedRegion(.center) {
          Text(shown.title).font(.headline).foregroundStyle(context.state.color(.textStrong)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if shown.timer, let started = context.state.started { DictationTimer(started: started, state: context.state) }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if shown.stop {
            DictationStopButton(id: context.attributes.id, state: context.state)
          } else if let body = shown.body {
            Text(body).font(.subheadline).foregroundStyle(context.state.color(.textSecondary)).lineLimit(1)
          }
        }
      } compactLeading: {
        Image(systemName: context.state.phase == .recording ? "mic.fill" : "waveform")
          .foregroundStyle(context.state.color(.primary))
      } compactTrailing: {
        if shown.timer, let started = context.state.started {
          Text(started, style: .timer).monospacedDigit().foregroundStyle(context.state.color(.textStrong)).frame(maxWidth: 44)
        } else if let elapsed = context.state.elapsed {
          Text(DictationActivityText.time(elapsed)).monospacedDigit().foregroundStyle(context.state.color(.textStrong))
        }
      } minimal: {
        Image(systemName: "mic.fill").foregroundStyle(context.state.color(.primary))
      }
      .widgetURL(DictationActivityText.url)
      .keylineTint(context.state.color(.primary))
    }
  }
}

private struct DictationSymbol: View {
  let state: DictationActivityAttributes.ContentState
  let size: CGFloat
  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(state.color(.primary))
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: state.phase == .recording ? "mic.fill" : state.phase == .paused ? "pause.fill" : "waveform")
          .font(.system(size: size * 0.45, weight: .bold))
          .foregroundStyle(state.color(.onPrimary))
      }
      .accessibilityHidden(true)
  }
}

private struct DictationTimer: View {
  let started: Date
  let state: DictationActivityAttributes.ContentState
  var body: some View {
    Text(started, style: .timer).font(.headline).monospacedDigit().multilineTextAlignment(.trailing)
      .foregroundStyle(state.color(.textStrong)).frame(width: 64, alignment: .trailing)
  }
}

/// "Parar gravação": wide, in the accent (it keeps the audio, it does not discard).
private struct DictationStopButton: View {
  let id: String
  let state: DictationActivityAttributes.ContentState
  var body: some View {
    Button(intent: StopDictationIntent(id: id)) {
      HStack(spacing: 6) {
        Image(systemName: "stop.fill")
        Text(DictationActivityText.stop)
      }
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(state.color(.onPrimary))
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(Capsule().fill(state.color(.primary)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(DictationActivityText.stop)
  }
}
