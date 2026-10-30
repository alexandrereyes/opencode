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

/// The approved ring (`opcao-1-anel-estados.png`) with the gap at the bottom where the mascot sits, drawn by the
/// shared state ring (rev. 30/10: a segment per state). The number is `N para você` in orange while something needs
/// Alexandre, otherwise the sessions working; with nothing active, the mascot alone over the gray track.
struct WatchRingView: View {
  /// Degrees open at the bottom for the mascot.
  static let opening: Double = 80
  let state: AgentsState?
  var lineWidth: CGFloat = 5
  var numberSize: CGFloat = 20

  var body: some View {
    let ring = AgentsStatusRing(counts: state?.counts)
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        AgentsStatusRingView(ring: ring, color: Color.watch, lineWidth: lineWidth, opening: Self.opening,
          gap: lineWidth * 0.6, accentable: true)
        if ring.number > 0 {
          Text(verbatim: "\(ring.number)")
            .font(.system(size: numberSize, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Color.watch(ring.forYou ? .primary : .textStrong))
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
    .accessibilityLabel(state?.summaryLabel ?? "Nenhuma sessão ativa")
  }
}

// MARK: Complications

struct ComplicationCircular: View {
  let state: AgentsState?
  var body: some View {
    WatchRingView(state: state, lineWidth: 4.5, numberSize: 19).padding(1)
  }
}

/// The corner's circle: the closed state ring around the number, or around the mascot when nothing is active.
struct ComplicationCorner: View {
  let state: AgentsState?
  var body: some View {
    let ring = AgentsStatusRing(counts: state?.counts)
    ZStack {
      AgentsStatusRingView(ring: ring, color: Color.watch, lineWidth: 3, gap: 2, accentable: true)
      if ring.number > 0 {
        Text(verbatim: "\(ring.number)").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
          .foregroundStyle(Color.watch(ring.forYou ? .primary : .textStrong)).minimumScaleFactor(0.6).padding(4)
      } else {
        WatchMascot().padding(8)
      }
    }
    .widgetLabel {
      Text(state?.complicationLine ?? "OpenCode")
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
          .lineLimit(state?.complicationDetail == nil ? 2 : 1).minimumScaleFactor(0.8)
        if let detail = state?.complicationDetail {
          Text(detail).font(.system(size: 11)).foregroundStyle(Color.watch(.textSecondary))
            .lineLimit(2).minimumScaleFactor(0.7)
        }
      }
      Spacer(minLength: 0)
    }
  }
}
