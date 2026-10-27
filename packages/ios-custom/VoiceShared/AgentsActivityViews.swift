import OpenCodeKit
import SwiftUI

/// Views of the "Agentes" Live Activity. They take plain attributes and state (not an `ActivityViewContext`), so
/// app-hosted tests can render them too. Rendering rules: `plugin-app-custom/docs/live-activity.md`.
///
/// The Lock Screen clips a Live Activity at 160 points, less than the approved mock's full layout with a focus and
/// a pending block. Fixed type sizes keep the height predictable, and `ViewThatFits` falls back from the mock's
/// layout to denser ones that keep every element of the contract.
struct AgentsLockScreenView: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    ViewThatFits(in: .vertical) {
      ForEach(AgentsDensity.allCases, id: \.self) { density in
        AgentsLockScreenLayout(attributes: attributes, state: state, density: density)
      }
    }
    .environment(\.locale, Locale(identifier: "pt_BR"))
  }
}

enum AgentsDensity: CaseIterable {
  /// The approved mock: activity on its own line, two-line pending rows.
  case regular
  /// Activity beside the project, one-line pending rows.
  case compact
  /// Also without the header row (the mascot and host move to the footer) and at most two pending rows.
  case tight
}

struct AgentsLockScreenLayout: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState
  let density: AgentsDensity

  var body: some View {
    VStack(alignment: .leading, spacing: density == .regular ? 7 : density == .compact ? 6 : 4) {
      if density != .tight {
        HStack(spacing: 6) {
          AgentsMascot(attributes: attributes).frame(width: 19, height: 16)
          Text("OpenCode").font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
          Spacer(minLength: 8)
          host
        }
      }
      if let focus = state.focus { AgentsFocusBlock(attributes: attributes, focus: focus, density: density) }
      if !state.attention.isEmpty { AgentsPendingBlock(attributes: attributes, state: state, density: density) }
      if state.focus == nil && state.attention.isEmpty && state.footer.isEmpty {
        Text("Nenhuma sessão ativa").font(.system(size: 13)).foregroundStyle(attributes.color(.textSecondary))
      }
      if density == .tight {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 6) {
            AgentsFooter(attributes: attributes, state: state).fixedSize()
            Spacer(minLength: 6)
            AgentsMascot(attributes: attributes).frame(width: 14, height: 12)
            host
          }
          AgentsFooter(attributes: attributes, state: state)
        }
      } else {
        AgentsFooter(attributes: attributes, state: state)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, density == .tight ? 7 : 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var host: some View {
    Text(state.host).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary)).lineLimit(1)
  }
}

struct AgentsFocusBlock: View {
  let attributes: AgentsActivityAttributes
  let focus: AgentsState.Focus
  let density: AgentsDensity

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 9) {
        AgentsAvatar(attributes: attributes, project: focus.project, size: 30)
        VStack(alignment: .leading, spacing: 0) {
          Text(focus.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
          Text(density == .regular ? focus.project : focus.activity.map { "\(focus.project) · \($0)" } ?? focus.project)
            .font(.system(size: 12)).foregroundStyle(attributes.color(.textSecondary))
        }.lineLimit(1)
        Spacer(minLength: 6)
        Text(timerInterval: focus.started...Date.distantFuture, countsDown: false)
          .font(.system(size: 14, weight: .medium, design: .monospaced)).monospacedDigit()
          .foregroundStyle(attributes.color(.textStrong))
          .multilineTextAlignment(.trailing).frame(width: 70, alignment: .trailing)
      }
      if density == .regular, let activity = focus.activity {
        Text(activity).font(.system(size: 12)).foregroundStyle(attributes.color(.text)).lineLimit(1)
      }
      if let progress = focus.progress {
        HStack(spacing: 8) {
          AgentsProgressBar(attributes: attributes, progress: progress).frame(height: 5)
          Text(progress.label).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary))
            .monospacedDigit().fixedSize()
        }
      }
    }
  }
}

/// Segmented like the approved mock while the total is small; a continuous bar beyond that.
struct AgentsProgressBar: View {
  let attributes: AgentsActivityAttributes
  let progress: AgentsState.Progress

  var body: some View {
    if progress.total <= 12 {
      HStack(spacing: 3) {
        ForEach(0..<max(progress.total, 1), id: \.self) { index in
          Capsule().fill(index < progress.done ? attributes.color(.primary) : attributes.color(.border))
        }
      }
    } else {
      ProgressView(value: progress.fraction).progressViewStyle(.linear).tint(attributes.color(.primary))
    }
  }
}

struct AgentsPendingBlock: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState
  let density: AgentsDensity

  var body: some View {
    let role = state.pendingRole
    let rows = Array(state.attention.prefix(density == .tight ? 2 : 3))
    VStack(alignment: .leading, spacing: density == .tight ? 2 : density == .regular ? 4 : 3) {
      HStack {
        Text(state.pendingTitle).font(.system(size: 10, weight: .semibold)).tracking(0.6)
          .foregroundStyle(attributes.color(role))
        Spacer(minLength: 6)
        if !state.pendingList, let first = state.attention.first { AgentsAgo(attributes: attributes, since: first.asked) }
      }
      if state.pendingList {
        ForEach(Array(rows.enumerated()), id: \.element.sessionID) { index, item in
          if index > 0 { Rectangle().fill(attributes.color(.border)).frame(height: 0.5) }
          Link(destination: link(item)) { listRow(item) }
        }
      } else if let item = state.attention.first {
        Link(destination: link(item)) { singleRow(item) }
      }
    }
    .padding(.horizontal, 10).padding(.vertical, density == .regular ? 7 : density == .compact ? 5 : 4)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(attributes.color(.surface).opacity(0.7)))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
      .strokeBorder(attributes.color(role).opacity(state.pendingList ? 0.25 : 0.6), lineWidth: 1))
  }

  private func singleRow(_ item: AgentsState.Attention) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 9) {
        AgentsAvatar(attributes: attributes, project: item.project, size: density == .regular ? 26 : 24)
        VStack(alignment: .leading, spacing: 0) {
          Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
          if density == .regular || item.text == nil {
            Text(item.project).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary))
          } else if let text = item.text {
            Text(text).font(.system(size: 12)).foregroundStyle(attributes.color(.text))
          }
        }.lineLimit(1)
        Spacer(minLength: 4)
        if density != .regular, item.text != nil {
          Text(item.project).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary)).lineLimit(1)
        }
        chevron
      }
      if density == .regular, let text = item.text {
        Text(text).font(.system(size: 12)).foregroundStyle(attributes.color(.text)).lineLimit(1)
      }
    }
  }

  private func listRow(_ item: AgentsState.Attention) -> some View {
    HStack(spacing: 8) {
      AgentsAvatar(attributes: attributes, project: item.project, size: density == .regular ? 24 : 18)
      if density == .regular {
        VStack(alignment: .leading, spacing: 0) {
          Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
          Text(item.project).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary))
        }.lineLimit(1).layoutPriority(1)
      } else {
        Text("\(Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))) \(Text(item.project).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary)))")
          .lineLimit(1).layoutPriority(1)
      }
      Spacer(minLength: 4)
      if Set(state.attention.map(\.kind)).count > 1 {
        Image(systemName: item.kind == .permission ? "hand.raised.fill" : "questionmark")
          .font(.system(size: 10, weight: .bold)).foregroundStyle(attributes.color(item.kind.role))
      }
      AgentsAgo(attributes: attributes, since: item.asked)
      chevron
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
      .foregroundStyle(attributes.color(.textSecondary))
  }

  private func link(_ item: AgentsState.Attention) -> URL {
    AgentsDeepLink.session(serverKey: attributes.serverKey, sessionID: item.sessionID, directory: item.directory).url
  }
}

/// `há 3 min.`, kept current by the system without activity updates.
struct AgentsAgo: View {
  let attributes: AgentsActivityAttributes
  let since: Date
  var body: some View {
    Text(.currentDate, format: AgentsText.ago(since: since))
      .font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary)).lineLimit(1)
      .multilineTextAlignment(.trailing).frame(maxWidth: 62, alignment: .trailing)
  }
}

/// The non-zero counts. When all five do not fit, the dots go first, then the text scales down.
struct AgentsFooter: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row(dots: true, spacing: 6).fixedSize()
      row(dots: false, spacing: 4).fixedSize()
      row(dots: false, spacing: 3).minimumScaleFactor(0.7)
    }
    .font(.system(size: 11)).lineLimit(1)
  }

  private func row(dots: Bool, spacing: CGFloat) -> some View {
    HStack(spacing: spacing) {
      ForEach(Array(state.footer.enumerated()), id: \.element.label) { index, item in
        if index > 0 { Text(verbatim: "·").foregroundStyle(attributes.color(.textWeak)) }
        HStack(spacing: 4) {
          if dots && item.dot { Circle().fill(attributes.color(item.role)).frame(width: 6, height: 6) }
          Text(verbatim: "\(item.count)").foregroundStyle(attributes.color(item.role)).fontWeight(.semibold)
          Text(item.label).foregroundStyle(attributes.color(item.dot ? .text : .textSecondary))
        }
      }
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
    AgentsSegments(attributes: attributes, segments: state.compact)
    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
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

/// The expanded island: header and session rows in one bottom region. The island is at most about 160 points
/// tall, so `ViewThatFits` drops rows (3, then 2, then 1) instead of clipping one.
struct AgentsIslandExpanded: View {
  let attributes: AgentsActivityAttributes
  let state: AgentsState

  var body: some View {
    ViewThatFits(in: .vertical) {
      ForEach([3, 2, 1], id: \.self) { limit in content(limit) }
    }
  }

  private func content(_ limit: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        AgentsMascot(attributes: attributes).frame(width: 24, height: 20)
        AgentsSegments(attributes: attributes, segments: state.header)
          .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
      }.padding(.bottom, 6)
      ForEach(Array(state.sessions.prefix(limit).enumerated()), id: \.element.sessionID) { _, row in
        Rectangle().fill(attributes.color(.border)).frame(height: 0.5)
        Link(destination: AgentsDeepLink.session(serverKey: attributes.serverKey, sessionID: row.sessionID,
          directory: row.directory).url) {
          HStack(spacing: 10) {
            AgentsAvatar(attributes: attributes, project: row.project, size: 24)
            VStack(alignment: .leading, spacing: 0) {
              Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(attributes.color(.textStrong))
              Text(row.project).font(.system(size: 11)).foregroundStyle(attributes.color(.textSecondary))
            }.lineLimit(1)
            Spacer(minLength: 6)
            Text(row.statusLabel).font(.system(size: 12)).foregroundStyle(attributes.color(row.statusRole))
              .lineLimit(1).monospacedDigit()
          }.padding(.vertical, 3)
        }
      }
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

/// Coordinates follow the 1024-point app icon; the drawing's bounds are x 145…885, y 185…810.
struct AgentsMascotShape: Shape {
  enum Part { case body, visor, eyes, spark }
  let part: Part

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width / 740, rect.height / 625)
    let origin = CGPoint(x: rect.midX - 370 * scale, y: rect.midY - 312.5 * scale)
    func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
      CGRect(x: origin.x + (x - 145) * scale, y: origin.y + (y - 185) * scale, width: width * scale,
        height: height * scale)
    }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + (x - 145) * scale, y: origin.y + (y - 185) * scale)
    }
    func star(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, into path: inout Path) {
      let pull: CGFloat = 0.16
      path.move(to: point(x, y - height))
      path.addQuadCurve(to: point(x + width, y), control: point(x + width * pull, y - height * pull))
      path.addQuadCurve(to: point(x, y + height), control: point(x + width * pull, y + height * pull))
      path.addQuadCurve(to: point(x - width, y), control: point(x - width * pull, y + height * pull))
      path.addQuadCurve(to: point(x, y - height), control: point(x - width * pull, y - height * pull))
      path.closeSubpath()
    }
    var path = Path()
    switch part {
    case .body:
      path.addRoundedRect(in: box(225, 282, 575, 528), cornerSize: CGSize(width: 250 * scale, height: 230 * scale),
        style: .continuous)
      path.addRoundedRect(in: box(145, 452, 160, 220), cornerSize: CGSize(width: 80 * scale, height: 80 * scale))
      path.addRoundedRect(in: box(720, 452, 160, 220), cornerSize: CGSize(width: 80 * scale, height: 80 * scale))
      star(757, 325, 128, 140, into: &path)
    case .visor:
      path.addRoundedRect(in: box(265, 433, 492, 247), cornerSize: CGSize(width: 123 * scale, height: 123 * scale))
    case .eyes:
      path.addRoundedRect(in: box(382, 500, 61, 122), cornerSize: CGSize(width: 30 * scale, height: 30 * scale))
      path.addRoundedRect(in: box(578, 500, 61, 122), cornerSize: CGSize(width: 30 * scale, height: 30 * scale))
    case .spark:
      star(757, 325, 70, 76, into: &path)
    }
    return path
  }
}
