import OpenCodeKit
import SwiftUI

// The Nova sessão pieces the iPhone's screen and the Mac's sheet share.

struct ProjectAvatar: View {
  @Environment(\.appTheme) private var theme
  let project: Project
  let size: CGFloat
  let style: AppTextStyle
  var body: some View {
    if let icon = ProjectIcon.of(project) {
      ProjectIconAvatar(icon: icon, size: size).accessibilityHidden(true)
    } else {
      let colors = theme.avatar(SessionList.avatarColor(project, fallback: project.id))
      Text(SessionList.monogram(project.displayName)).appFont(style, weight: .medium)
        .minimumScaleFactor(0.6).lineLimit(1)
        .foregroundStyle(colors.text).frame(width: size, height: size)
        .background(colors.background, in: Circle()).accessibilityHidden(true)
    }
  }
}

/// The managed chats destination, drawn like the web's speech-bubble Chats item.
struct ChatsAvatar: View {
  @Environment(\.appTheme) private var theme
  let size: CGFloat
  let symbol: AppSymbolSize
  var body: some View {
    Image(systemName: "bubble.left").appSymbol(symbol)
      .foregroundStyle(theme.color(.icon)).frame(width: size, height: size)
      .background(theme.color(.highlight), in: Circle()).accessibilityHidden(true)
  }
}

struct GitBranchIcon: View {
  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 4, y: 5))
      path.addLine(to: CGPoint(x: 4, y: 13))
      path.move(to: CGPoint(x: 12, y: 5))
      path.addQuadCurve(to: CGPoint(x: 4, y: 10), control: CGPoint(x: 12, y: 10))
      for center in [CGPoint(x: 4, y: 3), CGPoint(x: 4, y: 15), CGPoint(x: 12, y: 3)] {
        path.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
      }
      context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }.frame(width: 16, height: 18).accessibilityHidden(true)
  }
}

struct MCPChip: View {
  @Environment(\.appTheme) private var theme
  let server: MCPServer
  let preview: Bool
  var chat = false
  let toggle: () -> Void
  @State private var pulse = false
  private var disabled: Bool { server.status.status == .disabled }
  private var pending: Bool { server.status.status == .pending }
  private var dotRole: ThemeRole {
    switch server.status.status {
    case .connected: .success
    case .failed: .error
    case .needsAuth: .warning
    default: .textWeak
    }
  }
  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 7) {
        Circle().fill(theme.color(dotRole)).frame(width: 7, height: 7)
          .opacity(pending && pulse ? 0.3 : 1)
        Text(server.name).appFont(.caption).lineLimit(1).frame(maxWidth: 184)
          .foregroundStyle(theme.color(disabled ? .textWeak : .text))
      }.padding(.horizontal, 12).frame(minHeight: 32)
        .overlay {
          Capsule().strokeBorder(
            theme.color(.border), style: StrokeStyle(lineWidth: 0.8, dash: disabled ? [4, 3] : []))
        }
    }.buttonStyle(.plain).disabled(pending || server.status.status == .unknown)
      .opacity(pending ? 0.6 : 1)
      .accessibilityRepresentation {
        Toggle(isOn: Binding(get: { server.enabled }, set: { _ in toggle() })) {
          Text(server.name)
        }.disabled(pending || server.status.status == .unknown)
          .accessibilityHint(
            preview
              ? (chat
                ? "Prévia. Vale quando o chat for criado."
                : "Prévia. Vale quando a worktree for criada.")
              : "Altera o MCP para todas as sessões deste diretório."
          )
          .accessibilityValue(server.status.status.label)
          .accessibilityIdentifier("mcp-" + server.name)
      }
      .task(id: pending) {
        guard pending else {
          pulse = false
          return
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
      }
  }
}

struct MCPFlowLayout: Layout {
  let spacing: CGFloat
  var centered = true
  private func rows(_ subviews: Subviews, width: CGFloat) -> [[LayoutSubview]] {
    var rows: [[LayoutSubview]] = [[]]
    var used: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if used > 0 && used + spacing + size.width > width {
        rows.append([])
        used = 0
      }
      rows[rows.count - 1].append(view)
      used += size.width + (used > 0 ? spacing : 0)
    }
    return rows
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 360
    let heights = rows(subviews, width: width).map { row in
      row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    }
    return CGSize(
      width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing)
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(subviews, width: bounds.width) {
      let sizes = row.map { $0.sizeThatFits(.unspecified) }
      let width = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * spacing
      var x = centered ? bounds.midX - width / 2 : bounds.minX
      for (index, view) in row.enumerated() {
        view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[index]))
        x += sizes[index].width + spacing
      }
      y += (sizes.map(\.height).max() ?? 0) + spacing
    }
  }
}
