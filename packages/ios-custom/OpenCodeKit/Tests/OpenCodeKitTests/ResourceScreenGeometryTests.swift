import CoreGraphics
import Testing

@testable import OpenCodeKit

private let frame = CGSize(width: 588, height: 1280)

@Test func portraitFitsAndMapsTouchesToTheFrame() throws {
  let geometry = ResourceScreenGeometry(frame: frame)
  let bounds = CGRect(x: 0, y: 0, width: 600, height: 1000)
  let rect = geometry.screenRect(in: bounds)
  #expect(abs(rect.height - 1000) < 0.001)
  #expect(abs(rect.midX - 300) < 0.001 && rect.minX > 60)
  let point = try #require(geometry.framePoint(for: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.25), in: bounds))
  #expect(abs(point.x - 0.5) < 0.0001 && abs(point.y - 0.25) < 0.0001)
  // Letterbox bars are outside the screen; a clamped drag pins to its edge.
  #expect(geometry.framePoint(for: CGPoint(x: 1, y: 500), in: bounds) == nil)
  #expect(geometry.framePoint(for: CGPoint(x: 1, y: 500), in: bounds, clamped: true)?.x == 0)
}

/// serve-sim's `rawPointForDisplayPoint`: landscape_left (90°) raw = (y, 1 − x); landscape_right (270°) raw = (1 − y, x).
@Test(arguments: [
  (90, CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.7, y: 0.8)),
  (270, CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.3, y: 0.2)),
  (180, CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.8, y: 0.3)),
  (0, CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.2, y: 0.7)),
])
func uprightPointsUnrotateLikeServeSim(rotation: Int, upright: CGPoint, raw: CGPoint) {
  let mapped = ResourceScreenGeometry.unrotate(upright, rotation: rotation)
  #expect(abs(mapped.x - raw.x) < 0.0001 && abs(mapped.y - raw.y) < 0.0001)
  let back = ResourceScreenGeometry.rotate(mapped, rotation: rotation)
  #expect(abs(back.x - upright.x) < 0.0001 && abs(back.y - upright.y) < 0.0001)
}

@Test func landscapeSwapsTheFittedScreenAndRoundTrips() throws {
  let geometry = ResourceScreenGeometry(frame: frame, rotation: 90)
  #expect(geometry.upright == CGSize(width: 1280, height: 588))
  let bounds = CGRect(x: 0, y: 0, width: 402, height: 800)
  let rect = geometry.screenRect(in: bounds)
  #expect(abs(rect.width - 402) < 0.001 && rect.height < rect.width)
  let raw = CGPoint(x: 0.3, y: 0.9)
  let view = geometry.viewPoint(for: raw, in: bounds)
  let mapped = try #require(geometry.framePoint(for: view, in: bounds))
  #expect(abs(mapped.x - raw.x) < 0.0001 && abs(mapped.y - raw.y) < 0.0001)
}

@Test func rotationsNormalize() {
  #expect(ResourceScreenGeometry(frame: frame, rotation: -90).rotation == 270)
  #expect(ResourceScreenGeometry(frame: frame, rotation: 450).rotation == 90)
  #expect(ResourceScreenGeometry(frame: .zero).screenRect(in: CGRect(x: 0, y: 0, width: 10, height: 10)) == .zero)
}
