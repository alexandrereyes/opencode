import AppKit
import SwiftUI

/// A stroked arc turning clockwise forever, drawn and animated by Core Animation. A SwiftUI `repeatForever`
/// rotation makes SwiftUI lay out and render the window's hosting view on every frame, even with nothing else
/// changing; this layer animation runs in the render server and leaves the main thread idle.
struct MacSpinningArc: NSViewRepresentable {
  /// The arc, as `Circle().trim(from:to:)`: fractions of the circle clockwise from its rightmost point.
  let from: CGFloat
  let to: CGFloat
  let color: NSColor
  let lineWidth: CGFloat
  /// Seconds per turn; still while `animated` is false (Reduce Motion).
  let period: Double
  var animated = true
  /// A disc under the arc, `fillInset` inside its circle.
  var fill: NSColor? = nil
  var fillInset: CGFloat = 0

  func makeNSView(context: Context) -> ArcView { ArcView() }

  func updateNSView(_ view: ArcView, context: Context) {
    view.update(self)
  }

  final class ArcView: NSView {
    private let arc = CAShapeLayer()
    private let disc = CAShapeLayer()
    private var period = 0.0
    private var animated = false
    private var fillInset: CGFloat = 0

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layer?.masksToBounds = false
      arc.fillColor = nil
      arc.lineCap = .round
      layer?.addSublayer(disc)
      layer?.addSublayer(arc)
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ value: MacSpinningArc) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      arc.strokeStart = value.from
      arc.strokeEnd = value.to
      arc.strokeColor = value.color.cgColor
      arc.lineWidth = value.lineWidth
      disc.fillColor = value.fill?.cgColor
      disc.isHidden = value.fill == nil
      CATransaction.commit()
      if fillInset != value.fillInset {
        fillInset = value.fillInset
        needsLayout = true
      }
      if period != value.period || animated != value.animated {
        period = value.period
        animated = value.animated
        restart()
      }
    }

    override func layout() {
      super.layout()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      arc.frame = bounds
      arc.path = circle(in: bounds)
      disc.frame = bounds.insetBy(dx: fillInset, dy: fillInset)
      disc.path = CGPath(ellipseIn: disc.bounds, transform: nil)
      CATransaction.commit()
      if arc.animation(forKey: "turn") == nil { restart() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // Turns once in a window; a turn already running keeps its phase.
      if arc.animation(forKey: "turn") == nil { restart() }
    }

    /// From the rightmost point, clockwise on screen like SwiftUI's `Circle`: this view is not flipped, so its
    /// layers' y grows upward and clockwise runs toward negative angles.
    private func circle(in rect: CGRect) -> CGPath {
      let path = CGMutablePath()
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
        startAngle: 0, endAngle: -2 * .pi, clockwise: true)
      return path
    }

    private func restart() {
      arc.removeAnimation(forKey: "turn")
      guard animated, period > 0, window != nil else { return }
      let turn = CABasicAnimation(keyPath: "transform.rotation.z")
      turn.fromValue = 0
      turn.toValue = -2 * Double.pi
      turn.duration = period
      turn.repeatCount = .infinity
      turn.isRemovedOnCompletion = false
      arc.add(turn, forKey: "turn")
    }
  }
}
