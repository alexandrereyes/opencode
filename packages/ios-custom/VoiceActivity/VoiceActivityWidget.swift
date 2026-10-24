import ActivityKit
import AppIntents
import OpenCodeKit
import SwiftUI
import WidgetKit

@main struct VoiceActivityBundle: WidgetBundle {
  var body: some Widget {
    VoiceActivityWidget()
    VoiceStartControl()
  }
}

/// Assignable to the Action button, Control Center and the Lock Screen. The intent runs in the app
/// process and asks for authentication on a locked iPhone.
struct VoiceStartControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "br.com.alexandrem.opencode.voice-start") {
      ControlWidgetButton(action: StartVoiceIntent()) {
        Label("Falar com a mestra", systemImage: "waveform")
          .controlWidgetActionHint("Falar com a Sessão mestra")
      }
    }
    .displayName("Falar com a mestra")
    .description("Inicia a conversa por voz sem abrir o OpenCode. Exige o iPhone desbloqueado.")
  }
}

struct VoiceActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
      HStack(spacing: 14) {
        Image(systemName: context.state.symbol)
          .foregroundStyle(context.state.color(.accent))
        VStack(alignment: .leading, spacing: 4) {
          Text("OpenCode · Voz").font(.caption).foregroundStyle(context.state.color(.textSecondary))
          Text(context.state.label).font(.headline).foregroundStyle(context.state.color(.textStrong))
        }
        Spacer(minLength: 0)
        controls(context)
      }.padding(16).activityBackgroundTint(context.state.color(.background))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { Image(systemName: "waveform").foregroundStyle(context.state.color(.accent)) }
        DynamicIslandExpandedRegion(.center) { Text(context.state.label).font(.headline).foregroundStyle(context.state.color(.textStrong)) }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.attributes.started, style: .timer).font(.caption.monospacedDigit())
            .foregroundStyle(context.state.color(.textSecondary))
        }
        DynamicIslandExpandedRegion(.bottom) { controls(context).padding(.top, 8) }
      } compactLeading: {
        Image(systemName: context.state.muted ? "mic.slash.fill" : context.state.symbol).foregroundStyle(context.state.color(.accent))
      } compactTrailing: {
        Image(systemName: context.state.working ? "brain" : "mic.fill").foregroundStyle(context.state.color(.accent))
      } minimal: {
        Image(systemName: "waveform").foregroundStyle(context.state.color(.accent))
      }
    }
  }
  private func controls(_ context: ActivityViewContext<VoiceActivityAttributes>) -> some View {
    HStack(spacing: 16) {
      Button(intent: VoiceMuteIntent(sessionID: context.attributes.sessionID)) {
        Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill")
          .frame(width: 44, height: 44).foregroundStyle(context.state.color(.textStrong))
      }.accessibilityLabel(context.state.muted ? "Reativar microfone" : "Silenciar microfone")
      Button(intent: VoiceEndIntent(sessionID: context.attributes.sessionID)) {
        Image(systemName: "phone.down.fill").frame(width: 44, height: 44)
          .foregroundStyle(context.state.color(.error))
      }.accessibilityLabel("Encerrar conversa por voz")
    }.buttonStyle(.plain)
  }
}
