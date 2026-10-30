import OpenCodeKit
import SwiftUI

/// Draws `AgentsStatusRing` for the Live Activity (theme snapshot colors), its watch card, the complications and the
/// watch Painel (the watch palette): round-capped segments with a small gap between them, or the neutral track
/// alone when nothing counts. What goes in the middle (the number, the mascot) is the caller's.
struct AgentsStatusRingView: View {
  let ring: AgentsStatusRing
  let color: (ThemeRole) -> Color
  var lineWidth: CGFloat
  /// Degrees left open at the bottom (the watch's mascot sits there); 0 closes the circle.
  var opening: Double = 0
  /// Visible space between two segments, in points; the round caps get their own room on top of it.
  var gap: CGFloat = 3
  /// Complications: the segments follow the tint of accented watch faces, the track does not.
  var accentable = false

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let circumference = Double.pi * Double(max(side - lineWidth, 1))
      let arcs = ring.arcs(opening: opening, spacing: Double(lineWidth + gap) / circumference * 360)
      ZStack {
        if arcs.isEmpty {
          let track = AgentsStatusRing.track(opening: opening)
          AgentsRingArc(from: track.from, to: track.to, inset: lineWidth / 2)
            .stroke(color(.border), style: StrokeStyle(lineWidth: lineWidth, lineCap: opening > 0 ? .round : .butt))
        }
        ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
          AgentsRingArc(from: arc.from, to: arc.to, inset: lineWidth / 2)
            .stroke(color(arc.role).opacity(arc.dim ? 0.55 : 1),
              style: StrokeStyle(lineWidth: lineWidth, lineCap: arc.to - arc.from >= 360 ? .butt : .round))
            .widgetAccentable(accentable)
        }
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// An arc between two angles in degrees (SwiftUI's clockwise coordinates), `inset` inside the frame.
struct AgentsRingArc: Shape {
  let from: Double
  let to: Double
  var inset: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    Path { path in
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(min(rect.width, rect.height) / 2 - inset, 0),
        startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
    }
  }
}
