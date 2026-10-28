import OpenCodeKit
import SwiftUI

/// Owns the read-aloud player of one Markdown file, rendered or source, and floats its controls over the bottom
/// edge; leaving the file (close, paging, links, Voltar) stops it. The pill is always there for Markdown so reading
/// is one tap away without another toolbar button; nothing is generated until play.
struct ReadAloudHost: ViewModifier {
  let text: String?
  let title: String
  /// The file's absolute path, which keys its saved reading place on the server.
  let path: String
  let client: OpenCodeClient
  @State private var player: ReadAloudPlayer?
  func body(content: Content) -> some View {
    content
      // The inset also gives the document room at its end, so the controls never hide the last lines.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let player { ReadAloudControls(player: player).padding(.horizontal, 12).padding(.bottom, 6) }
      }
      .modifier(ReadAloudPrompts(player: player))
      .task(id: text) {
        player?.stop()
        player = nil
        guard let text else { return }
        let rendered = MarkdownDocument.renderable(text)
        let blocks = await ResponseMarkdownCache.shared.parse(rendered)
        let pieces = ReadAloud.pieces(ReadAloud.segments(blocks, frontMatter: rendered != text))
        guard !Task.isCancelled, !pieces.isEmpty else { return }
        let player = ReadAloudPlayer(title: title, path: path, pieces: pieces, client: client)
        // Opening a document ends a reading elsewhere (a chat response), saving its place.
        ReadAloudPlayer.stopCurrent()
        self.player = player
        await player.restore()
      }
      .onDisappear { player?.stop() }
  }
}

/// Pauses reading when a voice call starts and asks before generating a very long text.
struct ReadAloudPrompts: ViewModifier {
  @Environment(\.voiceController) private var voice
  let player: ReadAloudPlayer?
  func body(content: Content) -> some View {
    content
      .onChange(of: voice?.state.visible == true) { _, calling in if calling { player?.pause() } }
      .alert("Ouvir documento longo?", isPresented: Binding(get: { player?.confirmation != nil },
        set: { if !$0 { player?.confirmation = nil } })) {
        Button("Ouvir") { player?.confirm() }
        Button("Cancelar", role: .cancel) { player?.confirmation = nil }
      } message: {
        if let confirmation = player?.confirmation {
          Text("São cerca de \(Int((confirmation.seconds / 60).rounded())) minutos de áudio. Gerar tudo custaria até "
            + confirmation.usd.formatted(.currency(code: "USD").locale(Locale(identifier: "pt_BR")))
            + "; só é gerado o trecho que você ouvir, e trechos já ouvidos não são cobrados de novo.")
        }
      }
  }
}

/// A compact pill in the trailing corner (play with a progress ring, time, speed) that expands into the full player:
/// play, a draggable position over the whole document, elapsed/total time and speed. Until each piece has audio the
/// total is an estimate that settles while playing.
struct ReadAloudControls: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let player: ReadAloudPlayer
  /// In a conversation, the full player offers to scroll back to the answer being read.
  var reveal: (() -> Void)? = nil
  @State private var expanded = false
  @State private var scrub: Double?
  @State private var editing = false
  private var position: Double { scrub ?? player.position }
  private var failure: String? { if case .failed(let message) = player.phase { message } else { nil } }
  var body: some View {
    Group {
      if expanded || failure != nil { panel.transition(transition(.bottom)) }
      else { HStack { Spacer(minLength: 0); pill }.transition(transition(.bottomTrailing)) }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: expanded)
    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: failure)
  }

  private var pill: some View {
    HStack(spacing: 0) {
      ReadAloudPlayButton(player: player, progress: progress)
      Button { expanded = true } label: {
        time.padding(.horizontal, 6).frame(minHeight: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Abrir player")
      .accessibilityValue("\(ReadAloud.clock(position)) de \(ReadAloud.clock(player.total))")
      .accessibilityIdentifier("read-aloud-expand")
      rate.padding(.trailing, 4)
    }
    .padding(2)
    .adaptiveGlass(Capsule())
    .accessibilityElement(children: .contain).accessibilityIdentifier("read-aloud-pill")
  }

  private var panel: some View {
    VStack(spacing: 0) {
      HStack {
        if let reveal {
          Button("Ir para a resposta") { Haptics.play(.selection); reveal() }
            .appFont(.footnote).buttonStyle(.plain).foregroundStyle(theme.color(.primary)).lineLimit(1)
            .frame(minHeight: 44).contentShape(Rectangle())
            .accessibilityIdentifier("read-aloud-reveal")
        } else {
          Text("Lendo em voz alta").appFont(.footnote).foregroundStyle(theme.color(.textSecondary)).lineLimit(1)
        }
        Spacer(minLength: 0)
        if player.saved {
          Button("Recomeçar do início") { Haptics.play(.selection); player.restart() }
            .appFont(.footnote).buttonStyle(.plain).foregroundStyle(theme.color(.primary))
            .frame(minHeight: 44).padding(.horizontal, 4).contentShape(Rectangle())
            .accessibilityIdentifier("read-aloud-restart")
        }
        Button { expanded = false } label: {
          Image(systemName: "chevron.down").appSymbol(.action).frame(width: 44, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(theme.color(.textSecondary))
        .accessibilityLabel("Recolher player").accessibilityIdentifier("read-aloud-collapse")
      }
      .padding(.leading, 12)
      if let failure {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill").appSymbol(.action).foregroundStyle(theme.color(.error))
            .frame(width: 44, height: 44).accessibilityHidden(true)
          Text(failure).appFont(.caption).foregroundStyle(theme.color(.text)).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("read-aloud-error")
          Button("Tentar novamente") { player.retry() }
            .appFont(.caption).buttonStyle(.bordered).tint(theme.color(.primary))
            .frame(minHeight: 44).accessibilityIdentifier("read-aloud-retry")
        }
        .padding(.horizontal, 6).padding(.bottom, 6)
      } else {
        HStack(spacing: 4) {
          ReadAloudPlayButton(player: player, progress: progress)
          VStack(alignment: .leading, spacing: 0) {
            Slider(value: Binding(get: { position }, set: { value in
              if editing { scrub = value } else { player.seek(to: value) }
            }), in: 0...max(1, player.total)) { started in
              editing = started
              if !started, let scrub { player.seek(to: scrub); self.scrub = nil }
            }
            .tint(theme.color(.primary))
            .accessibilityLabel("Posição da leitura")
            .accessibilityValue("\(ReadAloud.clock(position)) de \(ReadAloud.clock(player.total))")
            .accessibilityIdentifier("read-aloud-progress")
            time
          }
          rate
        }
        .padding(.horizontal, 6).padding(.bottom, 6)
      }
    }
    .adaptiveGlass(RoundedRectangle(cornerRadius: 26))
    .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 40 { expanded = false } })
    .accessibilityElement(children: .contain).accessibilityIdentifier("read-aloud-panel")
  }

  private var progress: Double { player.total > 0 ? min(1, position / player.total) : 0 }

  private var time: some View {
    Text("\(ReadAloud.clock(position)) / \(ReadAloud.clock(player.total))")
      .appFont(.footnote).monospacedDigit().foregroundStyle(theme.color(.textSecondary)).lineLimit(1).fixedSize()
      .accessibilityIdentifier("read-aloud-time")
  }

  private var rate: some View {
    Button { Haptics.play(.selection); player.cycleRate() } label: {
      Text(ReadAloudPlayer.label(player.rate)).appFont(.caption).monospacedDigit().fontWeight(.semibold)
        .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 30)
        .background(theme.color(.surfaceRaised), in: .capsule)
        .frame(minHeight: 44).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(theme.color(.text))
    .accessibilityLabel("Velocidade").accessibilityValue(ReadAloudPlayer.label(player.rate))
    .accessibilityIdentifier("read-aloud-rate")
  }

  private func transition(_ anchor: UnitPoint) -> AnyTransition {
    reduceMotion ? .opacity : .scale(scale: 0.92, anchor: anchor).combined(with: .opacity)
  }
}

/// Play/pause inside a ring that fills with the reading; a spinner while the piece at the playhead is generated.
private struct ReadAloudPlayButton: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.voiceController) private var voice
  let player: ReadAloudPlayer
  let progress: Double
  var body: some View {
    Button {
      Haptics.play(.light)
      if case .failed = player.phase { player.retry() } else { player.toggle() }
    } label: {
      ZStack {
        Circle().stroke(theme.color(.border), lineWidth: 2.5)
        Circle().trim(from: 0, to: progress).stroke(theme.color(.primary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
        if player.phase == .loading {
          ProgressView().controlSize(.small).tint(theme.color(.primary))
        } else {
          Image(systemName: player.phase == .playing ? "pause.fill" : "play.fill").appSymbol(.action)
            .foregroundStyle(theme.color(.primary))
        }
      }
      .padding(4).frame(width: 46, height: 46).contentShape(Circle())
    }
    .buttonStyle(.plain).disabled(voice?.state.visible == true)
    .accessibilityLabel(label)
    .accessibilityIdentifier("read-aloud-play")
  }
  private var label: String {
    switch player.phase {
    case .playing: "Pausar leitura"
    case .loading: "Gerando áudio, toque para cancelar"
    default: "Ouvir documento"
    }
  }
}

extension ReadAloudPlayer {
  static func label(_ rate: Float) -> String { rate == 1.5 ? "1,5×" : "\(Int(rate))×" }
}
