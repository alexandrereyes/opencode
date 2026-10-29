import OpenCodeKit
import SwiftUI
import WidgetKit

/// Views of the "Agentes" Live Activity. They take plain attributes and state (not an `ActivityViewContext`), so
/// app-hosted tests can render them too. Rendering rules: `plugin-app-custom/docs/live-activity.md`.
///
/// Heights are deterministic: every block has a fixed frame from `AgentsLayout`, never measured with `ViewThatFits`
/// (the system clips instead of proposing its limit).

/// Lock Screen card, "ring and counters" (Option A, 29/10: attention first): while something needs Alexandre, the
/// ring of those counts with `N para você`, their lines before `trabalhando` and the first of them; otherwise the
/// ring of the work with `activeTotal`. It summarizes all sessions and never singles one out.
struct AgentsLockScreenView: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        AgentsMascot(attributes: attributes).frame(width: 19, height: 16)
        Text("OpenCode").font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
        Spacer(minLength: 8)
        Text(state.host).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary)).lineLimit(1)
      }.frame(height: AgentsLayout.lockHeader)
      rule
      HStack(spacing: 16) {
        AgentsGaugeView(attributes: attributes, state: state)
          .frame(width: AgentsLayout.lockRing, height: AgentsLayout.lockRing)
        VStack(alignment: .leading, spacing: 0) {
          ForEach(state.counters, id: \.label) { counter in
            AgentsCounterLine(attributes: attributes, counter: counter).frame(height: AgentsLayout.lockCounter)
          }
          if state.counters.isEmpty {
            Text("Nenhuma sessão ativa").font(.system(size: 14)).foregroundStyle(attributes.color(.textSecondary))
              .frame(height: AgentsLayout.lockCounter)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(height: AgentsLayout.lockRing)
      if let line = state.attentionLine {
        rule
        AgentsAttentionRow(attributes: attributes, line: line).frame(height: AgentsLayout.lockAttention)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, AgentsLayout.lockPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.locale, Locale(identifier: "pt_BR"))
  }

  /// A hairline with the fixed gap above and below it.
  private var rule: some View {
    Rectangle().fill(attributes.color(.border)).frame(height: 0.5)
      .frame(height: AgentsLayout.lockRule).padding(.vertical, AgentsLayout.lockGap)
  }
}

/// The closed ring of the Lock Screen card, with `N para você` or `N ativas` in the centre.
struct AgentsGaugeView: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    let width = AgentsLayout.lockRingWidth
    // The round caps cover `width` along the circle, so the gap also makes room for them.
    let circumference = Double.pi * Double(AgentsLayout.lockRing - width)
    let arcs = state.gauge(gap: (Double(width) + 4) / circumference)
    ZStack {
      if arcs.isEmpty { Circle().stroke(attributes.color(.border), lineWidth: width).padding(width / 2) }
      ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
        AgentsArc(from: arc.from, to: arc.to)
          .stroke(attributes.color(arc.role).opacity(arc.dim ? 0.55 : 1),
            style: StrokeStyle(lineWidth: width, lineCap: arcs.count > 1 ? .round : .butt))
          .padding(width / 2)
      }
      VStack(spacing: -2) {
        Text(verbatim: "\(state.gaugeNumber)").font(.system(size: 26, weight: .bold)).monospacedDigit()
          .foregroundStyle(attributes.color(.textStrong))
        Text(state.gaugeLabel).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary))
      }
    }
  }
}

struct AgentsCounterLine: View {
  let attributes: AgentsActivityAttributes
  let counter: AgentsCounter

  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(attributes.color(counter.role)).frame(width: 8, height: 8)
      Text(verbatim: "\(counter.count) \(counter.label)")
        .font(.system(size: 15, weight: counter.emphasized ? .semibold : .regular))
        .foregroundStyle(attributes.color(counter.emphasized ? .textStrong : .textSecondary))
        .lineLimit(1).minimumScaleFactor(0.8)
    }
  }
}

/// `● Escolher banco do cache · pergunta · há 3 min. +1`: the title truncates first. Each run is its own view, and
/// the system-updated date never gets `fixedSize`: the Lock Screen then failed to archive the card and showed it empty.
struct AgentsAttentionRow: View {
  let attributes: AgentsActivityAttributes
  let line: AgentsAttentionLine

  var body: some View {
    HStack(spacing: 0) {
      Circle().fill(attributes.color(line.role)).frame(width: 8, height: 8).padding(.trailing, 8)
      Text(line.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
        .lineLimit(1).truncationMode(.tail)
      Text(verbatim: " · \(line.kind)").font(.system(size: 12)).foregroundStyle(attributes.color(.textSecondary))
        .lineLimit(1).layoutPriority(1)
      if let since = line.since {
        Text(verbatim: " · ").font(.system(size: 12)).foregroundStyle(attributes.color(.textSecondary))
          .layoutPriority(1)
        // On the Lock Screen a system-updated date claims all free width, so it gets a fixed one ("há 59 min.").
        Text(.currentDate, format: AgentsText.ago(since: since)).font(.system(size: 12))
          .foregroundStyle(attributes.color(.textSecondary)).lineLimit(1).minimumScaleFactor(0.8)
          .frame(width: AgentsLayout.lockAgo, alignment: .leading)
      }
      if let more = line.more {
        // Neutral: the others may be of the other kind.
        Text(verbatim: "  +\(more)").font(.system(size: 12, weight: .semibold))
          .foregroundStyle(attributes.color(.text)).lineLimit(1).layoutPriority(1)
      }
      Spacer(minLength: 0)
    }
  }
}

struct AgentsAvatar: View {
  let attributes: AgentsActivityAttributes
  let project: String
  let size: CGFloat

  var body: some View {
    Text(SessionList.monogram(project))
      .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
      .frame(width: size, height: size)
      .background(Circle().fill(attributes.color(AgentsTheme.avatar(project)).opacity(0.72)))
  }
}

// MARK: Dynamic Island

struct AgentsCompactTrailing: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState
  var body: some View {
    if state.forYou > 0 {
      // `N para você`: the number in an orange pill, like the watch card's badge.
      Text(verbatim: "\(state.forYou)").font(.system(size: 15, weight: .bold)).monospacedDigit()
        .foregroundStyle(attributes.color(.background))
        .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 20)
        .background(Capsule().fill(attributes.color(.primary)))
    } else {
      AgentsSegments(attributes: attributes, segments: state.compact)
        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
    }
  }
}

/// One text made of colored runs, so it wraps and scales as a whole.
struct AgentsSegments: View {
  let attributes: AgentsActivityAttributes
  let segments: [AgentsSegment]
  var body: some View {
    segments.reduce(Text(verbatim: "")) { text, part in
      Text("\(text)\(Text(part.text).foregroundStyle(attributes.color(part.role)))")
    }
  }
}

struct AgentsMinimalView: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState
  var body: some View {
    let minimal = state.minimal
    if let symbol = minimal.symbol, let count = minimal.count {
      HStack(spacing: 1) {
        Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
        Text(verbatim: "\(count)").font(.system(size: 13, weight: .bold)).monospacedDigit()
      }.foregroundStyle(attributes.color(minimal.role))
    } else {
      ZStack {
        Circle().strokeBorder(attributes.color(.success), lineWidth: 2)
        AgentsMascot(attributes: attributes).padding(5)
      }
    }
  }
}

/// The expanded island: header and single-line rows in the bottom region, at fixed heights: the first two that
/// need Alexandre, or the sessions when nothing does. Each row opens its session. The row count comes from
/// `AgentsLayout.island`, so the content never passes the region's measured limit.
struct AgentsIslandExpanded: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    let layout = AgentsLayout.island(state)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        AgentsMascot(attributes: attributes).frame(width: 21, height: 18)
        AgentsSegments(attributes: attributes, segments: state.header)
          .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
      }.frame(height: AgentsLayout.islandHeader)
      if layout.rows > 0 { Spacer().frame(height: AgentsLayout.islandGap) }
      ForEach(Array(state.islandRows.prefix(layout.rows).enumerated()), id: \.element.sessionID) { _, row in
        Link(destination: AgentsDeepLink.session(serverKey: attributes.serverKey, sessionID: row.sessionID,
          directory: row.directory).url) { line(row) }
          .frame(height: AgentsLayout.islandRow)
          .overlay(alignment: .top) { Rectangle().fill(attributes.color(.border)).frame(height: 0.5) }
      }
      if let more = layout.more {
        Text(verbatim: "+\(more)").font(.system(size: 10, weight: .medium)).foregroundStyle(attributes.color(.textSecondary))
          .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24)
          .frame(height: AgentsLayout.islandMore)
      }
    }
    .frame(height: layout.height, alignment: .top)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func line(_ row: AgentsState.Row) -> some View {
    HStack(spacing: 8) {
      AgentsAvatar(attributes: attributes, project: row.project, size: 16)
      Text("\(Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong)))  \(Text(row.project).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary)))")
        .lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 6)
      Text(state.statusLabel(row)).font(.system(size: 12)).foregroundStyle(attributes.color(state.statusRole(row)))
        .lineLimit(1).monospacedDigit().fixedSize()
    }
    .frame(maxHeight: .infinity)
  }
}

// MARK: Apple Watch

/// The Lock Screen closure's content: the iPhone card, or the Apple Watch Smart Stack card (`.small`).
struct AgentsActivityContent: View {
  @Environment(\.activityFamily) private var family
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    switch family {
    case .small: AgentsWatchView(attributes: attributes, state: state)
    default: AgentsLockScreenView(attributes: attributes, state: state)
    }
  }
}

/// Smart Stack card (approved mock `smartstack-b3-anel-segmentado.png`): the mascot inside the subagent ring with the
/// attention badge, and the first two sessions. Fixed metrics fit the smallest watch's 152 × 69.5 points.
struct AgentsWatchView: View {
  static let height: CGFloat = 64
  static let ring: CGFloat = 44
  static let row: CGFloat = 30
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    HStack(spacing: 6) {
      ZStack(alignment: .bottom) {
        AgentsRingView(attributes: attributes, ring: state.ring)
          .overlay { AgentsMascot(attributes: attributes).padding(9) }
          .frame(width: Self.ring, height: Self.ring)
        if let badge = state.watchBadge { badgeView(badge).offset(y: 3) }
      }
      .frame(width: Self.ring, height: Self.height)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(state.watchRows.enumerated()), id: \.element.sessionID) { index, row in
          if index > 0 { Rectangle().fill(attributes.color(.border)).frame(height: 0.5).padding(.vertical, 1.75) }
          line(row).frame(height: Self.row, alignment: .leading)
        }
        if state.watchRows.isEmpty {
          Text("Nenhuma sessão ativa").font(.system(size: 12)).foregroundStyle(attributes.color(.textSecondary))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: Self.height)
    .padding(.horizontal, 4)
    .environment(\.locale, Locale(identifier: "pt_BR"))
  }

  private func badgeView(_ badge: AgentsMinimal) -> some View {
    HStack(spacing: 1) {
      if let symbol = badge.symbol { Image(systemName: symbol).font(.system(size: 8, weight: .heavy)) }
      if let count = badge.count { Text(verbatim: "\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit() }
    }
    .foregroundStyle(attributes.color(.background))
    .padding(.horizontal, 5).frame(height: 15)
    .background(Capsule().fill(attributes.color(badge.role)))
  }

  private func line(_ row: AgentsState.Row) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(row.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
        .lineLimit(1).truncationMode(.tail)
      // The status label wins over the time, which truncates first.
      HStack(spacing: 0) {
        Text(state.statusLabel(row)).layoutPriority(1)
        if let asked = state.asked(row) {
          Text(verbatim: " · ")
          Text(.currentDate, format: AgentsText.ago(since: asked))
        }
      }
      .font(.system(size: 11, weight: .medium)).foregroundStyle(attributes.color(state.statusRole(row))).lineLimit(1)
      .minimumScaleFactor(0.85)
    }
  }
}

/// Segments with small gaps for up to eight subagents, one continuous arc above that, a full ring while working
/// without subagents, and only the track when nothing works.
struct AgentsRingView: View {
  let attributes: AgentsActivityAttributes
  let ring: AgentsRing
  private let style = StrokeStyle(lineWidth: 4, lineCap: .round)

  var body: some View {
    ZStack {
      switch ring {
      case .segments(let done, let total):
        let gap = total > 1 ? 0.07 : 0
        ForEach(0..<total, id: \.self) { index in
          let start = Double(index) / Double(total)
          AgentsArc(from: start + gap / 2, to: start + 1 / Double(total) - gap / 2)
            .stroke(attributes.color(index < done ? .success : .border), style: style)
        }
      case .continuous(let fraction):
        Circle().stroke(attributes.color(.border), style: style)
        AgentsArc(from: 0, to: fraction).stroke(attributes.color(.success), style: style)
      case .full:
        Circle().stroke(attributes.color(.success), style: style)
      case .track:
        Circle().stroke(attributes.color(.border), style: style)
      }
    }
    .padding(style.lineWidth / 2)
  }
}

/// An arc from 12 o'clock, clockwise, between two fractions of the circle.
struct AgentsArc: Shape {
  let from: Double
  let to: Double
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
        startAngle: .degrees(from * 360 - 90), endAngle: .degrees(to * 360 - 90), clockwise: false)
    }
  }
}

// MARK: Mascot

/// The app icon's robot, drawn with theme colors so the extension needs no image asset.
struct AgentsMascot: View {
  let attributes: AgentsActivityAttributes
  var body: some View {
    ZStack {
      AgentsMascotShape(part: .body).fill(attributes.color(.primary))
      AgentsMascotShape(part: .visor).fill(attributes.color(.background))
      AgentsMascotShape(part: .eyes).fill(attributes.color(.accent))
      AgentsMascotShape(part: .spark).fill(attributes.color(.accent))
    }
    .aspectRatio(740.0 / 625.0, contentMode: .fit)
    .accessibilityLabel("OpenCode")
  }
}
