import OpenCodeKit
import SwiftUI

extension DictationCaptures {
  /// Opens the dictation's own composer, the way a Live Activity link opens a session.
  static func open(_ place: DictationPlace, sessions: SessionStore) {
    sessions.settingsOpen = false
    switch place.route {
    case .conversation(let id)? where id == sessions.masterID:
      if sessions.conversationPath.last?.master != true { sessions.conversationPath = [.init(id: "master", master: true)] }
    case .conversation(let id)?:
      if sessions.conversationPath.last?.id != id { sessions.conversationPath = [.init(id: id)] }
    case .newSession?:
      if sessions.conversationPath.last?.newSession != true {
        sessions.conversationPath = [.init(id: "draft_" + UUID().uuidString, newSession: true)]
      }
    case nil: break
    }
  }
}

/// The dictation's strip while its composer is off screen, Abacato V2's `VoiceRecordingStripView` in OpenCode's
/// theme: recording, the level bars (a dot with Reduzir movimento), "Gravando para {destino}", the time and Parar;
/// paused or transcribing, the state and Revisar; the text landed elsewhere, "Texto pronto em {destino}", Revisar and
/// the X. A tap on the body opens the destination. The 4-second notice sits below. Controls in the primary color,
/// never the red of ending a call; each one is its own accessibility element.
struct DictationStripView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let captures: DictationCaptures
  let sessions: SessionStore
  var body: some View {
    if let strip = captures.strip {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          summary(strip)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { DictationCaptures.open(strip.place, sessions: sessions) }
            .accessibilityAddTraits(strip.place.route == nil ? [] : .isButton)
            .accessibilityHint(strip.place.route == nil ? "" : "Abre onde o texto vai entrar")
          controls(strip)
        }
        if let notice = captures.notice {
          Text(notice).appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.primary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("dictation-strip-notice")
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 8)
      .foregroundStyle(theme.color(.textStrong))
      .adaptiveGlass(RoundedRectangle(cornerRadius: 28))
      .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(theme.color(.border), lineWidth: 0.5) }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("dictation-strip")
      .onChange(of: captures.notice) { _, notice in
        if let notice { AccessibilityNotification.Announcement(notice).post() }
      }
    }
  }

  private func summary(_ strip: DictationCaptures.Strip) -> some View {
    HStack(spacing: 8) {
      if strip.kind == .recording {
        DictationStripIndicator(levels: captures.current?.levels ?? [], animated: !reduceMotion, color: theme.color(.primary))
          .frame(width: 30, height: 44).accessibilityHidden(true)
      } else if strip.kind == .transcribing {
        ProgressView().tint(theme.color(.primary)).frame(width: 30)
      }
      Text(strip.title).appFont(.body, weight: .semibold).lineLimit(1).truncationMode(.tail)
        .accessibilityIdentifier("dictation-strip-title")
      if let time = strip.time {
        Spacer(minLength: 4)
        Text(time).appFont(.body).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).fixedSize()
          .accessibilityLabel("Tempo gravado").accessibilityValue(time)
          .accessibilityIdentifier("dictation-strip-time")
      }
    }
  }

  @ViewBuilder
  private func controls(_ strip: DictationCaptures.Strip) -> some View {
    switch strip.kind {
    case .recording:
      capsule("Parar", identifier: "dictation-strip-stop", label: "Parar gravação e transcrever") {
        captures.current?.finish()
      }
    case .paused, .transcribing:
      if strip.place.route != nil {
        capsule("Revisar", identifier: "dictation-strip-review", label: "Revisar") {
          DictationCaptures.open(strip.place, sessions: sessions)
        }
      }
    case .ready:
      if strip.place.route != nil {
        capsule("Revisar", identifier: "dictation-strip-review", label: "Revisar") {
          captures.dismissReady()
          DictationCaptures.open(strip.place, sessions: sessions)
        }
      }
      Button(action: captures.dismissReady) {
        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.color(.primary))
          .frame(width: 44, height: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Fechar aviso")
      .accessibilityIdentifier("dictation-strip-dismiss")
    }
  }

  private func capsule(_ title: String, identifier: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).appFont(.secondary, weight: .semibold).foregroundStyle(theme.color(.onPrimary))
        .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
        .background(Capsule().fill(theme.color(.primary))).contentShape(Capsule())
    }
    .buttonStyle(.plain).fixedSize()
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }
}

/// The strip's bars from the microphone's levels (the last six); a still dot with Reduzir movimento.
private struct DictationStripIndicator: View {
  let levels: [Float]
  let animated: Bool
  let color: Color
  var body: some View {
    if animated, !levels.isEmpty {
      Canvas { context, size in
        let shown = levels.suffix(6)
        let step = size.width / CGFloat(max(1, shown.count))
        for (index, level) in shown.enumerated() {
          let height = max(3, CGFloat(level) * size.height * 0.6)
          let bar = CGRect(x: CGFloat(index) * step + 1, y: (size.height - height) / 2, width: max(2, step - 2), height: height)
          context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(color))
        }
      }
    } else {
      Circle().fill(color).frame(width: 10, height: 10)
    }
  }
}
