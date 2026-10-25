import UIKit
import XCTest

@testable import OpenCode

/// The shell's touch overlay with a rotated stream (iOS Simulator in landscape): touches on the upright picture map
/// back to the unrotated frame the hub expects, and the letterbox stays outside.
@MainActor final class ResourceSurfaceTests: XCTestCase {
  func testTouchOverlayMapsTheUprightPictureBackToTheFrame() throws {
    let view = ResourceTouchOverlay.TouchView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    view.contentSize = CGSize(width: 588, height: 1280)

    let portrait = view.geometry.screenRect(in: view.bounds)
    XCTAssertEqual(portrait.height, 800, accuracy: 0.01)
    let center = try XCTUnwrap(view.geometry.framePoint(for: CGPoint(x: 200, y: 400), in: view.bounds))
    XCTAssertEqual(center.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(center.y, 0.5, accuracy: 0.0001)

    // landscape_left: the frame is shown turned 90° clockwise, 400 × 183.75 points in the middle of the view.
    view.rotation = 90
    let landscape = view.geometry.screenRect(in: view.bounds)
    XCTAssertEqual(landscape.width, 400, accuracy: 0.01)
    XCTAssertEqual(landscape.height, 183.75, accuracy: 0.01)
    // The upright top left is the frame's bottom left; the upright bottom right is its top right.
    let topLeft = try XCTUnwrap(view.geometry.framePoint(for: CGPoint(x: 0, y: landscape.minY), in: view.bounds))
    XCTAssertEqual(topLeft.x, 0, accuracy: 0.0001)
    XCTAssertEqual(topLeft.y, 1, accuracy: 0.0001)
    let bottomRight = try XCTUnwrap(view.geometry.framePoint(for: CGPoint(x: 400, y: landscape.maxY), in: view.bounds))
    XCTAssertEqual(bottomRight.x, 1, accuracy: 0.0001)
    XCTAssertEqual(bottomRight.y, 0, accuracy: 0.0001)
    XCTAssertNil(view.geometry.framePoint(for: CGPoint(x: 200, y: 100), in: view.bounds), "letterbox")
  }

  func testKeyboardFocusKeepsTheToolInStep() {
    let field = ResourceKeyboard.Field(frame: .zero)
    var active = false
    field.onBegin = { active = true }
    field.onEnd = { active = false }
    field.textFieldDidBeginEditing(field)
    XCTAssertTrue(active)
    field.textFieldDidEndEditing(field)
    XCTAssertFalse(active)
  }
}
