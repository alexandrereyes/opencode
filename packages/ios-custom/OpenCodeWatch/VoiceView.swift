import OpenCodeKit
import SwiftUI

/// Voz (`app-2-voz-mestra.png`): timer, Sessão mestra status, the mascot inside live audio levels (assistant on
/// top in lavender, Alexandre below in orange), the last two captions, Mute and End.
struct VoiceView: View {
  @Environment(\.dismiss) private var dismiss
  let call: VoiceCall
  let pairing: WatchPairing?

  var body: some View {
    VStack(spacing: 2) {
      status
      VoiceLevels(input: call.muted ? 0 : call.inputLevel, output: call.outputLevel, live: call.phase == .live)
        .frame(maxWidth: .infinity).frame(height: 104)
      if case .failed(let message) = call.phase {
        failure(message)
      } else {
        captions
        controls
      }
    }
    .ignoresSafeArea(.container, edges: .bottom)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if let connectedAt = call.connectedAt {
          Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
            .font(.system(size: 15, weight: .medium)).monospacedDigit().foregroundStyle(Color.watch(.textSecondary))
        }
      }
    }
    .navigationBarBackButtonHidden(call.phase == .live || call.phase == .connecting)
    .onAppear { if call.phase == .idle, let pairing { call.start(pairing: pairing) } }
    .onChange(of: call.phase) { _, phase in if phase == .idle { dismiss() } }
  }

  private var status: some View {
    let (text, role): (String, ThemeRole) = switch call.phase {
    case .connecting: ("Conectando…", .textSecondary)
    case .failed: ("Sem conexão", .error)
    case .idle: ("Encerrada", .textSecondary)
    case .live:
      if let master = call.timeline.master, master.running { (master.text, .warning) }
      else if call.outputLevel > 0.08 { ("Falando", .accent) }
      else { ("Ouvindo", .success) }
    }
    return VStack(spacing: 0) {
      Text("Sessão mestra").font(.system(size: 13)).foregroundStyle(Color.watch(.textSecondary))
      HStack(spacing: 5) {
        Circle().fill(Color.watch(role)).frame(width: 8, height: 8)
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.watch(role)).lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch-voice-status")
  }

  private var captions: some View {
    VStack(spacing: 1) {
      ForEach(Array(call.timeline.captions.lines.enumerated()), id: \.offset) { _, line in
        let user = line.role == .user
        Text("\(Text(user ? "Você: " : "Mestra: ").fontWeight(user ? .regular : .bold))\(Text(line.text))")
          .font(.system(size: user ? 12 : 13)).foregroundStyle(Color.watch(user ? .textSecondary : .textStrong))
          .multilineTextAlignment(.center).lineLimit(user ? 1 : 2)
      }
    }
    .frame(height: 34)
  }

  private var controls: some View {
    HStack(spacing: 18) {
      Button { call.toggleMute() } label: {
        Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill").font(.system(size: 20))
          .foregroundStyle(Color.watch(.textStrong))
      }
      .buttonStyle(.glass).buttonBorderShape(.circle).frame(width: 48, height: 48)
      .accessibilityLabel(call.muted ? "Ativar microfone" : "Silenciar")
      .accessibilityIdentifier("watch-voice-mute")
      Button { call.end() } label: {
        Image(systemName: "phone.down.fill").font(.system(size: 20)).foregroundStyle(Color.watch(.textStrong))
      }
      .buttonStyle(.glass).buttonBorderShape(.circle).tint(Color.watch(.error)).frame(width: 48, height: 48)
      .accessibilityLabel("Encerrar")
      .accessibilityIdentifier("watch-voice-end")
    }
  }

  private func failure(_ message: String) -> some View {
    VStack(spacing: 6) {
      Text(message).font(.footnote).multilineTextAlignment(.center).foregroundStyle(Color.watch(.textStrong))
      HStack {
        Button("Fechar") {
          call.dismissFailure()
          dismiss()
        }
        Button("Tentar de novo") { call.retry(pairing: pairing) }.tint(Color.watch(.primary))
      }.font(.footnote)
    }
  }
}

/// Radial level bars around the mascot. Only animates while the call is live.
private struct VoiceLevels: View {
  let input: Float
  let output: Float
  let live: Bool
  private let bars = 40

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !live)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      GeometryReader { proxy in
        let side = min(proxy.size.width, proxy.size.height)
        let radius = side * 0.34
        ZStack {
          ForEach(0..<bars, id: \.self) { index in
            let angle = Double(index) / Double(bars) * 2 * .pi
            // Top half: the assistant's voice; bottom half: Alexandre's microphone.
            let top = sin(angle - .pi / 2) < 0
            let level = Double(top ? output : input)
            let wave = 0.5 + 0.5 * sin(time * 7 + Double(index) * 1.7)
            let length = side * (0.03 + 0.13 * min(1, level * 1.6) * (0.4 + 0.6 * wave))
            Capsule()
              .fill(Color.watch(top ? .accent : .primary))
              .frame(width: 3, height: length)
              .offset(y: -(radius + length / 2))
              .rotationEffect(.radians(angle))
              .shadow(color: Color.watch(top ? .accent : .primary).opacity(0.6), radius: 3)
          }
          WatchMascot().frame(width: side * 0.44)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .accessibilityHidden(true)
  }
}
