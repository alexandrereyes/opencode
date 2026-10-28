import SwiftUI

/// Offers to keep paging toward a saved place older than an opening reads, below the pinned prompt.
struct ConversationViewportNotices: View {
  let state: TranscriptState
  let resume: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      if state.resumeOffered {
        Button("Retomar leitura", action: resume).buttonStyle(.glass)
      }
    }.font(.caption).padding(.top, state.stickyHeight + 8)
  }
}
