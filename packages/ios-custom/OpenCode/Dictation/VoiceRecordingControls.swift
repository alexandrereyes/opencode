import OpenCodeKit
import SwiftUI

struct VoiceRecordingTouchTarget: UIViewRepresentable {
  let available: Bool
  let event: (VoiceRecordingGesture.Event) -> Void
  func makeUIView(context: Context) -> TouchView { TouchView() }
  func updateUIView(_ view: TouchView, context: Context) {
    view.available = available; view.event = event
    view.isAccessibilityElement = available
    view.accessibilityElementsHidden = !available
    view.accessibilityTraits = available ? .button : []
    view.accessibilityIdentifier = available ? "dictation-microphone" : nil
    view.accessibilityLabel = available ? "Gravar para transcrever" : nil
    view.accessibilityHint = available ? "Toque para gravar com as mãos livres. Ou segure: deslize para cima para travar, para a esquerda para cancelar e solte para transcrever. Nada é enviado automaticamente." : nil
  }
  static func dismantleUIView(_ view: TouchView, coordinator: ()) { view.cancelTouch() }
  final class TouchView: UIView {
    var available = false
    var event: ((VoiceRecordingGesture.Event) -> Void)?
    private var origin: CGPoint?
    private var holdTask: Task<Void, Never>?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { available && super.point(inside: point, with: event) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard available, origin == nil, let touch = touches.first else { return }
      origin = touch.location(in: window)
      self.event?(.began)
      holdTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(VoiceRecordingGesture.holdDelay)) } catch { return }
        guard let self, origin != nil else { return }
        self.event?(.held)
      }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let origin, let point = touches.first?.location(in: window) else { return }
      self.event?(.moved(CGSize(width: point.x - origin.x, height: point.y - origin.y)))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard origin != nil else { return }
      holdTask?.cancel(); holdTask = nil; origin = nil
      self.event?(.ended)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTouch() }
    func cancelTouch() {
      holdTask?.cancel(); holdTask = nil
      guard origin != nil else { return }
      origin = nil; event?(.cancelled)
    }
    override func accessibilityActivate() -> Bool {
      guard available else { return false }
      event?(.began); event?(.ended); return true
    }
  }
}

struct DictationAction: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let recording: VoiceRecordingComposer
  let hasContent: Bool
  let canSubmit: Bool
  let sending: Bool
  let available: Bool
  let submit: () -> Void
  var submission = Submission.message
  /// A quote comment's action commits it to the message draft rather than sending.
  enum Submission { case message, comment }
  private var holding: Bool { recording.gesture.state == .holding }
  private var locked: Bool { recording.gesture.state == .locked && recording.capturing }
  var body: some View {
    ZStack {
      if holding {
        VStack(spacing: 14) {
          Image(systemName: "lock.open")
          Image(systemName: "chevron.up")
          Spacer(minLength: 48)
        }.appSymbol(.action).foregroundStyle(theme.color(.primary)).padding(.top, 14)
          .frame(width: 48, height: 140).glassEffect(.regular, in: .capsule)
          .offset(y: -66 + recording.gesture.offset.height * 0.35)
          .accessibilityHidden(true).allowsHitTesting(false)
      }
      if locked || hasContent || !available {
        Button {
          if locked { recording.finish() } else { submit() }
        } label: { face.frame(width: 44, height: 44).contentShape(Rectangle()) }
        .frame(width: 44, height: 44)
        .disabled(locked ? recording.state == .authorizing : !canSubmit)
        .opacity(!available && !hasContent && !locked ? 0.45 : 1)
        .accessibilityLabel(locked ? "Parar e transcrever" : hasContent ? submission == .message ? "Enviar mensagem" : "Concluir comentário" : "Gravar para transcrever")
        .accessibilityHint(!available && !hasContent && !locked ? "O microfone está indisponível no momento." : "")
        .accessibilityIdentifier(locked ? "dictation-stop" : hasContent ? submission == .message ? "composer-send" : "comment-done" : "dictation-microphone-disabled")
      } else {
        face.opacity(available ? 1 : 0.45).accessibilityHidden(true)
      }
    }
    .frame(width: 44, height: 44)
    // This target never unmounts while the finger moves from hold into the locked panel.
    .overlay {
      VoiceRecordingTouchTarget(available: available && !hasContent && (!recording.visible || holding || recording.state == .authorizing)) { recording.handle($0) }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: holding)
    .buttonStyle(.plain)
  }
  private var face: some View {
    Group {
      if sending || (recording.state == .authorizing && !holding) || recording.state == .pending { ProgressView().tint(theme.color(.onPrimary)) }
      else { Image(systemName: locked ? "stop.fill" : hasContent && !recording.visible ? submission == .message ? "arrow.up" : "checkmark" : "mic.fill").appSymbol(.action) }
    }.foregroundStyle(theme.color(.onPrimary))
      .frame(width: holding ? 64 : 36, height: holding ? 64 : 36)
      .background(theme.color(.primary), in: Circle())
      .offset(holding ? recording.gesture.offset : .zero)
  }
}

struct DictationRecordingPanel: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let recording: VoiceRecordingComposer
  private var holding: Bool { recording.gesture.state == .holding }
  var body: some View {
    Group {
      if typeSize.isAccessibilitySize && !holding && !recording.discarding {
        VStack(spacing: 8) {
          HStack { timer; waveform.frame(height: 44) }
          HStack {
            DictationIconButton(title: "Descartar gravação", symbol: "trash") { Haptics.play(.warning); recording.discard() }
              .accessibilityIdentifier("dictation-discard")
            if recording.state == .paused {
              DictationIconButton(title: recording.previewPlaying ? "Pausar pré-escuta" : "Ouvir gravação", symbol: recording.previewPlaying ? "pause.fill" : "play.fill") { recording.togglePreview() }
                .disabled(!recording.previewReady).accessibilityIdentifier("dictation-preview")
            }
            Spacer(minLength: 0)
            DictationIconButton(title: recording.state == .paused ? "Continuar gravação" : "Pausar gravação", symbol: recording.state == .paused ? "mic.fill" : "pause.circle") {
              Haptics.play(.light)
              if recording.state == .paused { recording.resume() } else { recording.pause() }
            }.accessibilityIdentifier("dictation-pause-resume")
          }
        }
      } else { compact }
    }.foregroundStyle(theme.color(.text)).buttonStyle(.plain).frame(minHeight: 44)
      .accessibilityElement(children: .contain).accessibilityIdentifier("dictation-recording")
  }
  private var compact: some View {
    HStack(spacing: 8) {
      if holding || recording.discarding {
        Image(systemName: recording.discarding ? "trash" : "record.circle")
          .appSymbol(.action)
          .foregroundStyle(theme.color(recording.discarding ? .text : .primary)).accessibilityHidden(true)
        timer.opacity(recording.discarding ? 0 : 1)
        Spacer(minLength: 0)
        Text("‹ Deslize para cancelar").appFont(.caption).lineLimit(2)
          .foregroundStyle(theme.color(.textSecondary))
          .offset(x: recording.gesture.offset.width * 0.5)
          .opacity(recording.discarding ? 0 : max(0, 1 + recording.gesture.offset.width / VoiceRecordingGesture.cancelDistance))
      } else {
        DictationIconButton(title: "Descartar gravação", symbol: "trash") { Haptics.play(.warning); recording.discard() }
          .accessibilityIdentifier("dictation-discard")
        if recording.state == .paused {
          DictationIconButton(title: recording.previewPlaying ? "Pausar pré-escuta" : "Ouvir gravação", symbol: recording.previewPlaying ? "pause.fill" : "play.fill") { recording.togglePreview() }
            .disabled(!recording.previewReady).accessibilityIdentifier("dictation-preview")
        }
        HStack(spacing: 8) {
          timer
          waveform.frame(height: 44)
        }.frame(maxWidth: .infinity)
        DictationIconButton(title: recording.state == .paused ? "Continuar gravação" : "Pausar gravação", symbol: recording.state == .paused ? "mic.fill" : "pause.circle") {
          Haptics.play(.light)
          if recording.state == .paused { recording.resume() } else { recording.pause() }
        }.accessibilityIdentifier("dictation-pause-resume")
      }
    }
  }
  private var timer: some View {
    let preview = recording.state == .paused && (recording.previewPlaying || recording.previewPosition > 0)
    let time = preview ? recording.previewPosition : recording.elapsed
    let seconds = Int(time)
    return Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
      .appFont(.caption).monospacedDigit().fixedSize()
      .accessibilityLabel(preview ? "Tempo reproduzido" : "Tempo gravado").accessibilityValue(VoiceRecordingAccessibility.duration(time))
      .accessibilityIdentifier("dictation-time")
  }
  private var waveform: some View {
    GeometryReader { geometry in
      // While recording, every frame slides the bars between the 100 ms meter samples instead of jumping a bar.
      TimelineView(.animation(paused: recording.state != .recording || reduceMotion)) { timeline in
        Canvas { context, size in
          let preview = recording.state == .paused
          let levels = preview ? recording.waveform : recording.levels
          let fraction = recording.previewDuration > 0 ? recording.previewPosition / recording.previewDuration : 0
          let step = size.width / CGFloat(levels.count)
          let shift = preview ? 0 : step * (reduceMotion ? 1 : min(1, max(0, timeline.date.timeIntervalSince(recording.sampledAt) / 0.1)))
          context.clip(to: Path(CGRect(origin: .zero, size: size)))
          for (index, level) in levels.enumerated() {
            let height = max(2, CGFloat(level) * min(22, size.height))
            context.fill(Path(roundedRect: CGRect(x: CGFloat(preview ? index : index + 1) * step - shift, y: (size.height - height) / 2,
              width: max(1, step - 2), height: height), cornerRadius: 1),
              with: .color(theme.color(preview && Double(index) / Double(levels.count) >= fraction ? .textSecondary : .primary)))
          }
          if preview {
            let cursor = CGRect(x: max(0, min(size.width - 20, size.width * fraction - 10)), y: (size.height - 20) / 2, width: 20, height: 20)
            context.fill(Path(ellipseIn: cursor), with: .color(theme.color(.primary)))
          }
        }
      }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged {
        recording.seekPreview(fraction: $0.location.x / max(1, geometry.size.width))
      }.onEnded {
        recording.seekPreview(fraction: $0.location.x / max(1, geometry.size.width))
      })
    }.accessibilityRepresentation {
      if recording.state == .paused {
        Slider(value: Binding(get: { recording.previewDuration > 0 ? recording.previewPosition / recording.previewDuration : 0 }, set: { recording.seekPreview(fraction: $0) }), in: 0...1)
          .accessibilityLabel("Posição da pré-escuta")
          .accessibilityValue("\(VoiceRecordingAccessibility.duration(recording.previewPosition)) de \(VoiceRecordingAccessibility.duration(recording.previewDuration))")
          .disabled(!recording.previewReady)
      }
    }
  }
}

private struct DictationIconButton: View {
  let title: String
  let symbol: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).appSymbol(.action).frame(width: 44, height: 44).contentShape(Rectangle())
    }.accessibilityLabel(title)
  }
}

struct DictationPendingView: View {
  @Environment(\.appTheme) private var theme
  let recording: VoiceRecordingComposer
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        if let job = recording.job, case .failed(let reason) = job.state {
          Text(reason).foregroundStyle(theme.color(.error))
          Button("Tentar de novo") { recording.retry() }.accessibilityIdentifier("dictation-retry")
        } else if let error = recording.error {
          Text(error).foregroundStyle(theme.color(.error))
          Button("Tentar de novo") { recording.retry() }
        } else {
          ProgressView().tint(theme.color(.primary))
          Text(recording.job?.state == .transcribing ? "Transcrevendo neste iPhone…" : recording.transcription.label)
        }
        Spacer(minLength: 0)
        Button("Descartar", role: .destructive) { Haptics.play(.warning); recording.discard() }.accessibilityIdentifier("dictation-discard-pending")
      }
      if recording.transcription.status == .missing {
        Button("Baixar modelo de transcrição") { recording.asksDownload = true }
      }
      if recording.transcription.status == .downloading {
        ProgressView(value: recording.transcription.progress).tint(theme.color(.primary))
        Text("\(TranscriptionSettingsView.size(recording.transcription.downloaded)) de \(TranscriptionSettingsView.size(recording.transcription.totalBytes)) · áudio aguardando no aparelho")
      }
      if case .failed = recording.transcription.status {
        Button("Tentar de novo") { recording.transcription.retry() }
      }
    }.appFont(.caption).foregroundStyle(theme.color(.textSecondary)).accessibilityIdentifier("dictation-pending")
  }
}
