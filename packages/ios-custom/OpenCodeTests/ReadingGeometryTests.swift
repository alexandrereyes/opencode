import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ReadingGeometryTests: XCTestCase {
  func testZeroSizeProbeUsesCellAndCapturedViewportOrigin() async throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.contentSize = CGSize(width: 400, height: 1200)
    window.rootViewController?.view.addSubview(scroll)
    let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 70, width: 400, height: 150))
    let probe = UIView(frame: .zero)
    scroll.addSubview(cell)
    cell.contentView.addSubview(probe)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let state = ConversationScrollState()
    state.view = scroll
    state.register(probe, id: "message")
    XCTAssertEqual(probe.bounds.height, 0)
    XCTAssertEqual(state.frames["message"]?.height, 150)
    state.readingAnchor = ("message", 80, 30)
    let moved = expectation(
      description: "Corrigiu a posição usando o topo capturado, não o cabeçalho atual")
    let observation = scroll.observe(\.contentOffset, options: .new) { _, _ in moved.fulfill() }
    defer { observation.invalidate() }
    state.correctAnchor()
    let result = await XCTWaiter.fulfillment(of: [moved], timeout: 2)
    XCTAssertEqual(result, .completed)
    XCTAssertEqual(scroll.contentOffset.y, 120, accuracy: 0.5)
    XCTAssertEqual(state.frames["message"]?.minY ?? 0, -50, accuracy: 0.5)
  }
}
