import OpenCodeKit
import SwiftUI

/// `openchamber-dark` colors for the watch app and its complications.
extension Color {
  static func watch(_ role: ThemeRole) -> Color {
    let color = WatchPalette.color(role)
    return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.opacity)
  }
}

extension AgentsState.Status {
  var watchSymbol: String? {
    switch self {
    case .question: "questionmark"
    case .permission: "hand.raised.fill"
    case .failed: "exclamationmark"
    case .working, .idle, .unknown: nil
    }
  }
}

/// The mascot drawn in theme colors (the complication tints it as a whole in accented modes).
struct WatchMascot: View {
  var body: some View {
    ZStack {
      AgentsMascotShape(part: .body).fill(Color.watch(.primary))
      AgentsMascotShape(part: .visor).fill(Color.watch(.background))
      AgentsMascotShape(part: .eyes).fill(Color.watch(.accent))
      AgentsMascotShape(part: .spark).fill(Color.watch(.accent))
    }
    .aspectRatio(740.0 / 625.0, contentMode: .fit)
    .accessibilityHidden(true)
  }
}

/// The approved ring (`opcao-1-anel-estados.png`): proportional arcs with a gap at the bottom where the mascot
/// sits, and the active count in the centre. With nothing active, the mascot alone over a gray ring.
struct WatchRingView: View {
  let state: AgentsState?
  var lineWidth: CGFloat = 5
  var numberSize: CGFloat = 20

  var body: some View {
    let ring = WatchRing(counts: state?.counts)
    let active = state?.activeTotal ?? 0
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        ForEach(Array(ring.arcs.enumerated()), id: \.offset) { index, arc in
          WatchArcShape(start: arc.start, end: arc.end, separated: ring.arcs.count > 1)
            .stroke(Color.watch(arc.role), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .widgetAccentable(arc.role != .border)
        }
        if active > 0 {
          Text(verbatim: "\(active)")
            .font(.system(size: numberSize, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Color.watch(.textStrong))
            .minimumScaleFactor(0.5)
            .offset(y: -side * 0.06)
          WatchMascot().frame(width: side * 0.42).offset(y: side * 0.36)
        } else {
          WatchMascot().frame(width: side * 0.56)
        }
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(state.map { [$0.activeLabel, $0.attentionLabel].compactMap { $0 }.joined(separator: ", ") }
      ?? "Nenhuma sessão ativa")
  }
}

/// One arc of the ring. The sweep runs clockwise from the left end of the bottom gap to its right end.
struct WatchArcShape: Shape {
  let start: Double
  let end: Double
  var separated = true

  func path(in rect: CGRect) -> Path {
    let sweep = 360 - WatchRing.gap
    // Bottom is 90° in SwiftUI's clockwise-down coordinates; the gap is centred there.
    let origin = 90 + WatchRing.gap / 2
    let pad = separated ? 7.0 : 0
    let from = origin + start * sweep + (start > 0 ? pad / 2 : 0)
    let to = origin + end * sweep - (end < 1 ? pad / 2 : 0)
    var path = Path()
    guard to > from else { return path }
    let inset = rect.insetBy(dx: 3, dy: 3)
    path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: min(inset.width, inset.height) / 2,
      startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
    return path
  }
}

// MARK: Complications

struct ComplicationCircular: View {
  let state: AgentsState?
  var body: some View {
    WatchRingView(state: state, lineWidth: 4.5, numberSize: 19).padding(1)
  }
}

struct ComplicationCorner: View {
  let state: AgentsState?
  var body: some View {
    let active = state?.activeTotal ?? 0
    ZStack {
      if active > 0 {
        Text(verbatim: "\(active)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
          .foregroundStyle(Color.watch(.textStrong))
      } else {
        WatchMascot().padding(6)
      }
    }
    .widgetLabel {
      Text(state?.attentionLabel ?? state?.activeLabel ?? "OpenCode")
    }
  }
}

/// How old the state is: `agora` in its first minute, then the live relative text (`há 3 min.`). `now` is the
/// timeline entry's date in a complication and the `TimelineView` date in the app, which re-render at the switch.
struct WatchAgeText: View {
  let fetched: Date
  let now: Date
  var body: some View {
    if WatchAge.isFresh(fetched, at: now) {
      Text("agora")
    } else {
      Text(.currentDate, format: AgentsText.ago(since: fetched))
    }
  }
}

struct ComplicationRectangular: View {
  let state: AgentsState?
  /// When the state was read from the Mac; nil before the first read.
  let fetched: Date?
  let now: Date
  var body: some View {
    HStack(spacing: 8) {
      WatchRingView(state: state, lineWidth: 3.5, numberSize: 15).frame(width: 46, height: 46)
      VStack(alignment: .leading, spacing: 1) {
        // The brand keeps its width; the age, smaller, shrinks first.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("OpenCode").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.watch(.primary))
            .widgetAccentable().lineLimit(1).fixedSize()
          Spacer(minLength: 0)
          if let fetched {
            WatchAgeText(fetched: fetched, now: now).font(.system(size: 10)).monospacedDigit()
              .foregroundStyle(Color.watch(.textSecondary)).lineLimit(1).minimumScaleFactor(0.7)
          }
        }
        Text(state.map(\.complicationLine) ?? "Nenhuma sessão ativa")
          .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.watch(.textStrong))
          .lineLimit(2).minimumScaleFactor(0.8)
      }
      Spacer(minLength: 0)
    }
  }
}
