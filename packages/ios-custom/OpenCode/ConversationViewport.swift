import Observation
import SwiftUI

@MainActor @Observable final class ConversationViewport {
  var jumpToLatest = false
  var stickyHeight: CGFloat = 0
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
