import OpenCodeKit
import SwiftUI

/// An activity group as a card: a disclosure header (`Atividade · Ler, Shell e Editar · 3 ferramentas · 1m12s`)
/// over the host's timeline. Shared by the iPhone and future Mac transcripts; the host owns the expansion
/// state and draws each item. A pending group refreshes its running span once a second.
struct ConversationActivityCard<Content: View>: View {
  @Environment(\.appTheme) private var theme
  let parts: [ConversationActivityPart]
  let expanded: Bool
  let pending: Bool
  let identifier: String
  let toggle: () -> Void
  @ViewBuilder let content: () -> Content
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
  @ScaledMetric(relativeTo: .footnote) private var detailSize: CGFloat = 13
  private let inset: CGFloat = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Only a pending group ticks: a settled card lays out once, like the rows around it, so prepending
      // history never re-measures it.
      if pending {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          header(now: context.date.timeIntervalSince1970 * 1000)
        }
      } else {
        header(now: Date().timeIntervalSince1970 * 1000)
      }
      if expanded {
        Rectangle().fill(theme.color(.border)).frame(height: 0.7).padding(.horizontal, 12)
        content().padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.surface), in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(.border), lineWidth: 0.7) }
    // The header's padding draws into the transcript's row spacing instead of growing the row: prepending
    // history while scrolling up slipped past the scroll owner's correction as collapsed groups grew taller.
    .padding(.vertical, -inset)
  }

  private func header(now: Double) -> some View {
    let header = ConversationActivityHeader(parts, now: now)
    return Button(action: toggle) {
      HStack(spacing: 8) {
        Image(systemName: expanded ? "chevron.down" : "chevron.right").appSymbol(.disclosure)
          .foregroundStyle(theme.color(.icon)).frame(width: 14)
        if pending { ProgressView().controlSize(.mini) }
        title(header)
          .monospacedDigit().multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 12).padding(.vertical, inset).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(header.label)
    .accessibilityValue(expanded ? "Expandido" : "Recolhido")
    .accessibilityIdentifier(identifier)
  }

  /// One line: the titles give way (truncated) so the count and the duration stay visible. Accessibility sizes
  /// wrap the whole header instead.
  @ViewBuilder private func title(_ header: ConversationActivityHeader) -> some View {
    let details = header.details.map { Text(" · " + $0) }
    if typeSize.isAccessibilitySize || details.isEmpty {
      Text("\(Text(header.title).font(.system(size: titleSize, weight: .medium)).foregroundStyle(theme.color(.text)))\(Text(header.details.map { " · " + $0 }.joined()).font(.system(size: detailSize)).foregroundStyle(theme.color(.textSecondary)))")
    } else {
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text(header.title).font(.system(size: titleSize, weight: .medium)).foregroundStyle(theme.color(.text)).fixedSize()
        details[0].lineLimit(1).truncationMode(.tail)
        if details.count > 1 {
          Text(header.details.dropFirst().map { " · " + $0 }.joined()).lineLimit(1).fixedSize()
        }
      }.font(.system(size: detailSize)).foregroundStyle(theme.color(.textSecondary))
    }
  }
}
