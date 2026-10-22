import Observation
import SwiftUI

@MainActor @Observable final class ConversationViewport {
  var unreadAbove = false
  var stickyHeight: CGFloat = 0
}

struct ConversationViewportNotices: View {
  let viewport: ConversationViewport
  let offersResume: Bool
  let unreadID: String?
  let resume: () -> Void
  let reveal: (String) -> Void

  var body: some View {
    VStack(spacing: 8) {
      if offersResume {
        Button("Retomar leitura", action: resume).buttonStyle(.glass)
      }
      if viewport.unreadAbove, let unreadID {
        Button("Novas mensagens ↑") { reveal(unreadID) }
          .buttonStyle(.glass).accessibilityLabel("Ir às novas mensagens")
      }
    }.font(.caption).padding(.top, viewport.stickyHeight + 8)
  }
}
