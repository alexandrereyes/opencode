import Observation
import OpenCodeKit
import SwiftUI

/// The conversation's read-aloud player: one answer at a time, keyed on the server by session and the answer's last
/// message, so its place survives reopening. Leaving the conversation stops it.
@MainActor @Observable final class ConversationReadAloud {
  private(set) var player: ReadAloudPlayer?
  /// The footer message of the answer being read.
  private(set) var messageID: String?
  @ObservationIgnored private var opening: Task<Void, Never>?

  /// The player while it is open; one stopped elsewhere (another reading, a document) is gone.
  var active: ReadAloudPlayer? { player.flatMap { $0.closed ? nil : $0 } }

  /// Reads an answer from its start, or opens it paused at its saved place so the pill shows where it stopped.
  func read(_ response: ReadAloud.Response, title: String, client: OpenCodeClient) {
    if let active, messageID == response.messageID {
      if !active.busy { active.play() }
      return
    }
    opening?.cancel()
    player?.stop()
    player = nil
    messageID = response.messageID
    opening = Task { [weak self] in
      let pieces = ReadAloud.pieces(ReadAloud.segments(await ResponseMarkdownCache.shared.parse(response.text)))
      guard let self, !Task.isCancelled, !pieces.isEmpty else { return }
      let player = ReadAloudPlayer(title: title, path: response.key, pieces: pieces, client: client)
      self.player = player
      await player.restore()
      guard !Task.isCancelled, self.player === player, !player.saved else { return }
      player.play()
    }
  }

  func stop() {
    opening?.cancel()
    player?.stop()
    player = nil
    messageID = nil
  }
}

/// Above the composer, trailing: the read-aloud pill (or its full player) with "Ir para a mais recente" stacked
/// above it, so neither covers the other. Reports its height so the transcript ends above it.
struct ConversationBottomControls: View {
  let readAloud: ConversationReadAloud
  let state: TranscriptState
  let jump: () -> Void
  let reveal: (String) -> Void
  let height: (CGFloat) -> Void
  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if state.jumpToLatest {
        Button(action: jump) {
          Image(systemName: "arrow.down").frame(width: 42, height: 42)
        }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Ir para a mais recente")
      }
      if let player = readAloud.active {
        ReadAloudControls(player: player, reveal: readAloud.messageID.map { id in { reveal(id) } })
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height($0) }
          .onDisappear { height(0) }
      }
    }
    .padding(12)
    .modifier(ReadAloudPrompts(player: readAloud.active))
  }
}
