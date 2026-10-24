import Observation
import SwiftUI

@MainActor @Observable final class ConversationViewport {
  var jumpToLatest = false
  var stickyHeight: CGFloat = 0
  /// The conversation's size; pinned prompts cap their text at 40% of its height.
  var promptSize = CGSize(width: 440, height: 800)
}

struct ConversationViewportNotices: View {
  let viewport: ConversationViewport
  let offersResume: Bool
  let resume: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      if offersResume {
        Button("Retomar leitura", action: resume).buttonStyle(.glass)
      }
    }.font(.caption).padding(.top, viewport.stickyHeight + 8)
  }
}
