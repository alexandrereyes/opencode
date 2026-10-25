import CoreGraphics

/// Where a rotated resource frame is drawn and how a touch on it maps back to the resource (iOS Simulator today).
///
/// The hub streams the simulator's unrotated framebuffer (portrait for an iPhone) and reports, in the stream's
/// `meta`, the clockwise `rotation` that shows it upright (`ios-simulator` adapter, `serve-sim.ts`). Input
/// coordinates stay in that unrotated frame, normalized to 0…1 with the origin at its top left, so the viewer
/// rotates the picture for display and un-rotates touches before sending them.
public struct ResourceScreenGeometry: Equatable, Sendable {
  /// Pixel size of the streamed (unrotated) frame.
  public var frame: CGSize
  /// Clockwise degrees: 0, 90, 180 or 270.
  public var rotation: Int

  public init(frame: CGSize, rotation: Int = 0) {
    self.frame = frame
    self.rotation = Self.normalized(rotation)
  }

  public static func normalized(_ degrees: Int) -> Int {
    let value = ((degrees % 360) + 360) % 360
    return [0, 90, 180, 270].min { abs($0 - value) < abs($1 - value) } ?? 0
  }

  /// Whether the upright screen swaps the frame's width and height.
  public var sideways: Bool { rotation == 90 || rotation == 270 }

  /// Size of the upright screen, in frame pixels.
  public var upright: CGSize { sideways ? CGSize(width: frame.height, height: frame.width) : frame }

  /// The upright screen fitted (aspect fit, centered) inside `bounds`.
  public func screenRect(in bounds: CGRect) -> CGRect {
    guard upright.width > 0, upright.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / upright.width, bounds.height / upright.height)
    let size = CGSize(width: upright.width * scale, height: upright.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                  width: size.width, height: size.height)
  }

  /// Normalized unrotated-frame point for a point in `bounds`. `nil` outside the screen unless `clamped`, which
  /// pins a drag that leaves the screen to its edge.
  public func framePoint(for point: CGPoint, in bounds: CGRect, clamped: Bool = false) -> CGPoint? {
    let rect = screenRect(in: bounds)
    guard rect.width > 0, rect.height > 0 else { return nil }
    let x = (point.x - rect.minX) / rect.width
    let y = (point.y - rect.minY) / rect.height
    let inside = (0...1).contains(x) && (0...1).contains(y)
    guard inside || clamped else { return nil }
    return Self.unrotate(CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)), rotation: rotation)
  }

  /// Point in `bounds` for a normalized unrotated-frame point; the inverse of `framePoint`.
  public func viewPoint(for frame: CGPoint, in bounds: CGRect) -> CGPoint {
    let rect = screenRect(in: bounds)
    let upright = Self.rotate(frame, rotation: rotation)
    return CGPoint(x: rect.minX + upright.x * rect.width, y: rect.minY + upright.y * rect.height)
  }

  /// Upright point for an unrotated-frame point (the frame turned clockwise by `rotation`).
  public static func rotate(_ point: CGPoint, rotation: Int) -> CGPoint {
    switch normalized(rotation) {
    case 90: CGPoint(x: 1 - point.y, y: point.x)
    case 180: CGPoint(x: 1 - point.x, y: 1 - point.y)
    case 270: CGPoint(x: point.y, y: 1 - point.x)
    default: point
    }
  }

  /// Unrotated-frame point for an upright point.
  public static func unrotate(_ point: CGPoint, rotation: Int) -> CGPoint {
    switch normalized(rotation) {
    case 90: CGPoint(x: point.y, y: 1 - point.x)
    case 180: CGPoint(x: 1 - point.x, y: 1 - point.y)
    case 270: CGPoint(x: 1 - point.y, y: point.x)
    default: point
    }
  }
}
