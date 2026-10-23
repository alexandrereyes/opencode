import OpenCodeKit
import SwiftUI

struct FloatingVoiceBar: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  let state: VoiceBarState
  let mute: () -> Void
  let end: () -> Void
  let retry: () -> Void
  let resume: () -> Void
  let expand: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button { expand(!state.expanded) } label: {
          HStack(spacing: 10) {
            VoiceWaveform(animated: state.animatesWaveform && !reduceMotion,
                          flat: state.muted || !state.animatesWaveform)
              .frame(width: 30, height: 26)
              .foregroundStyle(theme.color(.primary))
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 6) { status; time }
              VStack(alignment: .leading, spacing: 2) { status; time }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        HStack(spacing: 6) {
          Button(action: mute) {
            Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
              .frame(width: 44, height: 44)
              .background(theme.color(.surface).opacity(0.65), in: Circle())
              .overlay { Circle().strokeBorder(theme.color(.border), lineWidth: 0.5) }
          }
          .foregroundStyle(theme.color(state.muted ? .glassSecondary : .textStrong))
          .disabled(!state.muteEnabled)
          Button(action: end) {
            Image(systemName: "phone.down.fill").frame(width: 44, height: 44)
              .foregroundStyle(theme.color(.error))
              .background(theme.color(.error).opacity(0.15), in: Circle())
              .overlay { Circle().strokeBorder(theme.color(.error).opacity(0.4), lineWidth: 0.5) }
          }.disabled(state.busy)
        }.appSymbol(.action).buttonStyle(.plain)
      }
      if state.expanded {
        if let line = state.spokenLine {
          Text(line).appFont(.secondary)
            .foregroundStyle(theme.color(state.phase == .failed ? .error : .textStrong))
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle()).onTapGesture { expand(false) }
        }
        if let progress = state.progressLine {
          HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .foregroundStyle(theme.color(.accent))
            Text(progress).foregroundStyle(theme.color(.glassSecondary)).lineLimit(1)
            Spacer(minLength: 0)
            if reduceMotion {
              Image(systemName: "ellipsis").foregroundStyle(theme.color(.accent))
            } else { ProgressView().controlSize(.mini).tint(theme.color(.accent)) }
          }.appFont(.footnote).contentShape(Rectangle()).onTapGesture { expand(false) }
        }
      }
      if state.phase == .failed || state.phase == .interrupted {
        Button(action: state.phase == .failed ? retry : resume) {
          Label(state.phase == .failed ? "Tentar novamente" : "Retomar áudio",
                systemImage: state.phase == .failed ? "arrow.clockwise" : "play.fill")
            .appFont(.secondary, weight: .medium).frame(maxWidth: .infinity, minHeight: 44)
        }.foregroundStyle(theme.color(.accent)).disabled(state.busy)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 7)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
    .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(theme.color(.border), lineWidth: 0.5) }
    .contentShape(RoundedRectangle(cornerRadius: 28))
    .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
      if value.translation.height > 24 && abs(value.translation.height) > abs(value.translation.width) {
        expand(false)
      }
    })
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("floating-voice-bar")
    .accessibilityLabel(state.accessibilityLabel)
    .accessibilityValue([state.expanded ? "Expandida" : "Compacta", state.expanded ? state.spokenLine : nil,
                         state.expanded ? state.progressLine : nil].compactMap { $0 }.joined(separator: ". "))
    .accessibilityHint("Toque duas vezes para \(state.expanded ? "recolher" : "expandir")")
    .accessibilityAction { expand(!state.expanded) }
    .accessibilityAction(named: state.expanded ? "Recolher" : "Expandir") { expand(!state.expanded) }
    .accessibilityActions {
      if state.muteEnabled {
        Button(state.muted ? "Reativar microfone" : "Silenciar microfone", action: mute)
      }
      if state.phase == .failed { Button("Tentar novamente", action: retry) }
      if state.phase == .interrupted { Button("Retomar áudio", action: resume) }
      Button("Encerrar conversa por voz", action: end)
    }
  }

  private var status: some View {
    Text(state.label).appFont(.secondary, weight: .medium).lineLimit(1)
      .foregroundStyle(theme.color(state.phase == .failed ? .error : .primary))
  }
  private var time: some View {
    Text(state.time).appFont(.secondary).monospacedDigit().lineLimit(1).fixedSize()
      .foregroundStyle(theme.color(.glassSecondary))
  }
}

private struct VoiceWaveform: View {
  let animated: Bool
  let flat: Bool
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 20, paused: !animated)) { timeline in
      HStack(spacing: 3) {
        ForEach(0..<5) { index in
          Capsule().frame(width: 3, height: height(index, at: timeline.date))
        }
      }.frame(maxHeight: .infinity)
    }.accessibilityHidden(true)
  }
  private func height(_ index: Int, at date: Date) -> CGFloat {
    if flat { return 3 }
    let baseline = [10.0, 19, 26, 16, 8][index]
    if !animated { return baseline }
    return max(4, baseline * (0.7 + 0.3 * sin(date.timeIntervalSinceReferenceDate * 5 + Double(index))))
  }
}

#Preview("Expandida") {
  FloatingVoiceBar(state: .init(phase: .speaking, elapsed: 134,
    transcript: "Três sessões esperam você. Abro a primeira?", masterProgress: "lendo 3 sessões…", expanded: true),
    mute: {}, end: {}, retry: {}, resume: {}, expand: { _ in })
    .padding(16)
}
