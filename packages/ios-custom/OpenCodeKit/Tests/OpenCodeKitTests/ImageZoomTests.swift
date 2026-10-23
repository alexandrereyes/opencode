import Foundation
import Testing
@testable import OpenCodeKit

@Test func imageZoomFitsExtremeAspectRatiosAndRotation() {
  let portrait = CGSize(width: 400, height: 800)
  #expect(ImageZoomGeometry.fit(image: CGSize(width: 1000, height: 10000), viewport: portrait) == 0.08)
  #expect(ImageZoomGeometry.fit(image: CGSize(width: 10000, height: 1000), viewport: portrait) == 0.04)
  #expect(ImageZoomGeometry.fit(image: CGSize(width: 1000, height: 10000),
    viewport: CGSize(width: 800, height: 400)) == 0.04)
  #expect(ImageZoomGeometry.fit(image: CGSize(width: 40, height: 80), viewport: portrait) == 10)
  #expect(ImageZoomGeometry.fit(image: .zero, viewport: portrait) == 1)
}

@Test func imageZoomRectangleKeepsTappedPointCentered() {
  let point = CGPoint(x: 900, y: 1200)
  let rect = ImageZoomGeometry.rect(at: point, viewport: CGSize(width: 400, height: 800), scale: 2)
  #expect(rect.midX == point.x)
  #expect(rect.midY == point.y)
  #expect(rect.size == CGSize(width: 200, height: 400))
}
