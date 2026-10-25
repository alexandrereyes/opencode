import OpenCodeKit
import SwiftUI

/// Owns the read-aloud player of one Markdown file, rendered or source; leaving the file (close, paging, links,
/// Voltar) stops it. The toolbar button is a provisional control until the player's layout is chosen.
struct ReadAloudHost: ViewModifier {
  @Environment(\.voiceController) private var voice
  let text: String?
  let title: String
  let client: OpenCodeClient
  @State private var player: ReadAloudPlayer?
  func body(content: Content) -> some View {
    content
      .toolbar {
        if let player {
          ToolbarItem(placement: .topBarTrailing) {
            Button(label(player), systemImage: symbol(player)) {
              if case .failed = player.phase { player.retry() } else { player.toggle() }
            }
            .disabled(voice?.state.visible == true)
            .accessibilityValue("\(ReadAloud.clock(player.position)) de \(ReadAloud.clock(player.total)), \(player.rate)×")
            .accessibilityIdentifier("read-aloud-play")
          }
        }
      }
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
      .task(id: text) {
        player?.stop()
        player = nil
        guard let text else { return }
        let rendered = MarkdownDocument.renderable(text)
        let blocks = await ResponseMarkdownCache.shared.parse(rendered)
        let pieces = ReadAloud.pieces(ReadAloud.segments(blocks, frontMatter: rendered != text))
        guard !Task.isCancelled, !pieces.isEmpty else { return }
        player = ReadAloudPlayer(title: title, pieces: pieces, client: client)
      }
      .onDisappear { player?.stop() }
  }

  private func label(_ player: ReadAloudPlayer) -> String {
    switch player.phase {
    case .playing: "Pausar leitura"
    case .loading: "Gerando áudio"
    case .failed(let message): message
    default: "Ouvir documento"
    }
  }

  private func symbol(_ player: ReadAloudPlayer) -> String {
    switch player.phase {
    case .playing: "pause.fill"
    case .loading: "hourglass"
    case .failed: "exclamationmark.triangle"
    default: "play.fill"
    }
  }
}
