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

/// The attention complication (rev. 2026-11-01, `.agent-artifacts/watch-entry-points/complicacao-atencao-estados.png`):
/// the first kind of attention waiting, in the backend's precedence, as its symbol inside a ring of its color; with
/// nothing waiting, the gray mascot inside a gray track. Never a count, so only a kind appearing or clearing reloads it.
struct ComplicationCircular: View {
  let state: AgentsState?
  var body: some View {
    let attention = WatchAttention(state)
    AttentionBadge(kind: attention.top, lineWidth: 4.5).padding(1)
      .accessibilityElement(children: .ignore).accessibilityLabel(attention.accessibilityLabel)
  }
}

/// The corner's circle, with the kind (or `OpenCode`) along the bezel.
struct ComplicationCorner: View {
  let state: AgentsState?
  var body: some View {
    let attention = WatchAttention(state)
    AttentionBadge(kind: attention.top, lineWidth: 3)
      .widgetLabel {
        Text(attention.cornerLabel).foregroundStyle(Color.watch(attention.top?.role ?? .textSecondary))
      }
      .accessibilityElement(children: .ignore).accessibilityLabel(attention.accessibilityLabel)
  }
}

/// The symbol of a kind of attention inside a ring of its color, or the gray mascot inside a gray track. The symbol
/// and the ring take the face's tint; the shape alone tells the kinds apart there.
struct AttentionBadge: View {
  let kind: WatchAttention.Kind?
  let lineWidth: CGFloat
  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        Circle().strokeBorder(Color.watch(kind?.role ?? .textWeak), lineWidth: lineWidth)
          .opacity(kind == nil ? 0.7 : 1).widgetAccentable(kind != nil)
        if let kind {
          Image(systemName: kind.symbol).resizable().scaledToFit().fontWeight(.semibold)
            .foregroundStyle(Color.watch(kind.role)).frame(width: side * 0.5, height: side * 0.46).widgetAccentable()
        } else {
          WatchMascot().grayscale(1).opacity(0.8).frame(width: side * 0.56)
        }
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let attention = WatchAttention(state)
    HStack(spacing: 8) {
      AttentionBadge(kind: attention.top, lineWidth: 3).frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 2) {
        // The brand keeps its width; the age, smaller, shrinks first.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("MyAgents").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.watch(.primary))
            .widgetAccentable().lineLimit(1).fixedSize()
          Spacer(minLength: 0)
          if let fetched {
            WatchAgeText(fetched: fetched, now: now).font(.system(size: 10)).monospacedDigit()
              .foregroundStyle(Color.watch(.textSecondary)).lineLimit(1).minimumScaleFactor(0.7)
          }
        }
        line(attention).font(.system(size: 14, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(attention.accessibilityLabel)
  }

  /// One kind in its color (`Pergunta esperando`), several each in its own (`Pergunta · Erro`).
  private func line(_ attention: WatchAttention) -> Text {
    guard attention.kinds.count > 1 else {
      return Text(attention.line).foregroundStyle(Color.watch(attention.top?.role ?? .textSecondary))
    }
    return attention.kinds.enumerated().reduce(Text(verbatim: "")) { text, item in
      let separator = Text(verbatim: item.offset == 0 ? "" : " · ").foregroundStyle(Color.watch(.textSecondary))
      return Text("\(text)\(separator)\(Text(item.element.label).foregroundStyle(Color.watch(item.element.role)))")
    }
  }
}

/// The "Falar" complication (rev. 2026-11-01): a static microphone that opens Voz and starts a call on the watch. It
/// draws no state, so it never reloads.
struct VoiceComplicationCircular: View {
  static let label = "Falar com a Sessão mestra"
  var body: some View {
    ZStack {
      Circle().fill(Color.watch(.primary).opacity(0.2))
      Image(systemName: "mic.fill").font(.system(size: 22, weight: .semibold))
        .foregroundStyle(Color.watch(.primary)).widgetAccentable()
    }
    .padding(1)
    .accessibilityElement(children: .ignore).accessibilityLabel(Self.label)
  }
}

struct VoiceComplicationCorner: View {
  var body: some View {
    Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold))
      .foregroundStyle(Color.watch(.primary)).widgetAccentable()
      .widgetLabel { Text("Falar").foregroundStyle(Color.watch(.primary)) }
      .accessibilityElement(children: .ignore).accessibilityLabel(VoiceComplicationCircular.label)
  }
}

struct VoiceComplicationRectangular: View {
  var body: some View {
    HStack(spacing: 8) {
      VoiceComplicationCircular().frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text("MyAgents").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.watch(.primary))
          .widgetAccentable().lineLimit(1)
        Text("Falar com a mestra").font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.watch(.textStrong)).lineLimit(2).minimumScaleFactor(0.8)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .ignore).accessibilityLabel(VoiceComplicationCircular.label)
  }
}
