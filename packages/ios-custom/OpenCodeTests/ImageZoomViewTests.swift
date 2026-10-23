import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ImageZoomViewTests: XCTestCase {
  func testFitZoomBoundsCenteringPanningAndResize() throws {
    for size in [CGSize(width: 400, height: 4000), CGSize(width: 4000, height: 400)] {
      let image = UIGraphicsImageRenderer(size: size).image { _ in }.cgImage!
      let view = ImageZoomScrollView(image: image, name: "Teste", dismiss: {})
      view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
      view.layoutIfNeeded()
      let picture = try XCTUnwrap(view.viewForZooming(in: view))
      XCTAssertLessThanOrEqual(picture.frame.width, 400)
      XCTAssertLessThanOrEqual(picture.frame.height, 800)
      XCTAssertEqual(picture.frame.width + view.contentInset.left * 2, 400, accuracy: 0.01)
      XCTAssertEqual(picture.frame.height + view.contentInset.top * 2, 800, accuracy: 0.01)
      view.setZoomScale(view.minimumZoomScale / 2, animated: false)
      XCTAssertEqual(view.zoomScale, view.minimumZoomScale)
      view.setZoomScale(view.maximumZoomScale, animated: false)
      XCTAssertEqual(view.zoomScale / view.minimumZoomScale, 5, accuracy: 0.01)
      view.contentOffset = CGPoint(x: 60, y: 100)
      view.layoutIfNeeded()
      XCTAssertEqual(view.contentOffset.y, 100, accuracy: 0.01)
      view.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
      view.layoutIfNeeded()
      XCTAssertEqual(view.zoomScale, view.minimumZoomScale)
      XCTAssertEqual(picture.frame.width + view.contentInset.left * 2, 800, accuracy: 0.01)
      XCTAssertEqual(picture.frame.height + view.contentInset.top * 2, 400, accuracy: 0.01)
      XCTAssertEqual(view.contentOffset.x, -view.contentInset.left, accuracy: 0.01)
      XCTAssertEqual(view.contentOffset.y, -view.contentInset.top, accuracy: 0.01)
      XCTAssertTrue(picture.accessibilityActivate())
      XCTAssertEqual(picture.accessibilityCustomActions?.map(\.name), ["Ampliar", "Ajustar à tela", "Fechar imagem"])
    }
  }
}
