import SwiftUI

/// The OpenCode mascot as vector parts, shared by the iPhone app, its widget extension and the Apple Watch app
/// and complications.
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
