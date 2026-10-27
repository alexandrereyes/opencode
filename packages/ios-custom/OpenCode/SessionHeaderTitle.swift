import OpenCodeKit
import SwiftUI

/// A conversation's identity for a title bar: the project avatar inside its context ring, the title and
/// `path · trabalhando…`. Neutral (SwiftUI and OpenCodeKit only) so the iPhone header can adopt it; the Mac
/// app places it in its window toolbar.
struct SessionHeaderTitle: View {
  @Environment(\.appTheme) private var theme
  let row: SessionRow?
  let title: String
  let directory: SessionDirectoryLabel?
  let running: Bool
  let usage: ContextUsage?
  var avatar: CGFloat = 32

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        if let row {
          SessionAvatar(row: row, size: avatar)
        } else {
          Circle().fill(theme.color(.surfaceRaised)).frame(width: avatar, height: avatar)
        }
        if let usage {
          Circle().stroke(theme.color(.contextTrack), lineWidth: 2.5)
            .frame(width: avatar + 7, height: avatar + 7)
          Circle().trim(from: 0, to: usage.drawnFraction)
            .stroke(theme.color(usage.warning ? .contextWarning : .contextFill),
              style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: avatar + 7, height: avatar + 7)
        }
      }
      .frame(width: avatar + 8, height: avatar + 8)
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong)).lineLimit(1)
        HStack(spacing: 0) {
          if let directory {
            Text(URL(fileURLWithPath: directory.path).lastPathComponent)
              .lineLimit(1).truncationMode(.middle)
              .foregroundStyle(theme.color(.textSecondary))
          }
          if running {
            Text(directory == nil ? "trabalhando…" : " · trabalhando…").foregroundStyle(theme.color(.success))
              .fixedSize()
          }
        }
        .appFont(.caption)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      [title, directory?.accessibilityLabel, running ? "trabalhando" : nil, usage?.contextAccessibilityLabel]
        .compactMap { $0 }.joined(separator: ", "))
  }
}
