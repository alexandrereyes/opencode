import OpenCodeKit
import SwiftUI

/// A subagent conversation's header: `SUBAGENTE · NÍVEL 2 · ASTRAMAX` above the title, `de <parent>` below it, and
/// the levels from the top-level session down to this one (the badge's sheet and the back button's long press).
struct SubagentHeader {
  let kicker: String
  let subtitle: String
  let levels: [Session]
}

/// "Caminho": the top-level session, then each subagent down to the open one, as a small tree like the Mac's
/// sidebar. A level goes back to it; the open one says "você está aqui".
struct SubagentPathSheet: View {
  @Environment(\.appTheme) private var theme
  let levels: [Session]
  let current: String
  let sessions: SessionStore
  let choose: (String) -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Caminho").appFont(.heading, weight: .semibold).foregroundStyle(theme.color(.textStrong))
        Spacer(minLength: 0)
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary)).frame(width: 30, height: 30)
            .background(theme.color(.surface), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Fechar")
      }
      .padding(.horizontal, 16)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(levels.enumerated()), id: \.element.id) { depth, level in
            row(level, depth: depth)
          }
        }
        .padding(.horizontal, 12)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .padding(.top, 18)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(theme.color(.background))
  }

  private func row(_ level: Session, depth: Int) -> some View {
    let here = level.id == current
    let state = sessions.subagentState(level)
    return Button {
      if !here { choose(level.id) }
    } label: {
      HStack(spacing: 10) {
        if depth == 0 {
          Image(systemName: "house").appSymbol(.inline).foregroundStyle(theme.color(.textSecondary))
            .frame(width: 22, height: 22)
        } else {
          AgentPixels(color: theme.color(.accent), size: 18, running: sessions.active.contains(level.id), grid: true)
            .frame(width: 22, height: 22)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(level.displayTitle).appFont(.secondary, weight: here ? .semibold : .medium)
            .foregroundStyle(theme.color(.textStrong)).lineLimit(2)
          // `sessão principal · trabalhando · você está aqui`, the state in its color.
          Text("\(depth == 0 ? "sessão principal" : level.agent ?? "subagente") · \(Text(state).foregroundColor(theme.color(state == "trabalhando" ? .success : state == "precisa de você" ? .warning : .textSecondary)))\(here ? " · você está aqui" : "")")
            .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if !here {
          Image(systemName: "chevron.right").appSymbol(.disclosure).foregroundStyle(theme.color(.icon))
        }
      }
      .padding(10)
      .background(theme.color(.accent).opacity(here ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 10))
      .contentShape(Rectangle())
      .padding(.leading, CGFloat(depth) * 18)
      .overlay(alignment: .topLeading) {
        // Tree connector from the level above.
        if depth > 0 {
          Path { path in
            path.move(to: CGPoint(x: 0, y: -4))
            path.addLine(to: CGPoint(x: 0, y: 21))
            path.addLine(to: CGPoint(x: 9, y: 21))
          }
          .stroke(theme.color(.accent).opacity(0.45), lineWidth: 1)
          .offset(x: CGFloat(depth) * 18 - 8)
          .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(here ? .isSelected : [])
    .accessibilityIdentifier("subagent-path-" + level.id)
  }
}
