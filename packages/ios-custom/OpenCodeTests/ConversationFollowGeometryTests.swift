import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ConversationFollowGeometryTests: XCTestCase {
  private final class Scroll: UIScrollView {
    var simulatedDeceleration = false
    override var isDecelerating: Bool { simulatedDeceleration }
  }
  private final class Header: UIView, ConversationHeaderLayout {
    weak var scroll: UIScrollView?
    private var prepared = false
    func prepareForFollowing(offset: CGFloat) -> Bool {
      guard !prepared else { return false }
      prepared = true
      scroll?.contentSize.height -= 35
      return true
    }
  }

  func testExplicitFollowWaitsForExistingDeceleration() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    let scroll = Scroll(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.contentSize = CGSize(width: 400, height: 1400)
    window.rootViewController?.view.addSubview(scroll)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let state = ConversationScrollState()
    state.view = scroll
    defer { state.cancelAnchor() }
    scroll.simulatedDeceleration = true
    state.followToEnd()
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 0)
    scroll.simulatedDeceleration = false
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 0)
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 800)
    XCTAssertFalse(state.tailSettled)
    state.settle()
    state.settle()
    XCTAssertTrue(state.tailSettled)
    XCTAssertTrue(state.following)
    state.readingAnchor = ("old-reading-anchor", 10, nil)
    state.followToEnd()
    XCTAssertNil(state.readingAnchor)
    state.setVisible(false)
    scroll.contentSize.height = 1800
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 800)
  }

  func testHeaderCompactionSettlesBeforeFirstTailOffset() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    let scroll = Scroll(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.contentSize = CGSize(width: 400, height: 1400)
    let cell = UICollectionReusableView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    let header = Header(frame: .zero)
    header.scroll = scroll
    cell.addSubview(header)
    scroll.addSubview(cell)
    window.rootViewController?.view.addSubview(scroll)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let state = ConversationScrollState()
    state.view = scroll
    state.registerHeader(header, container: cell, id: "prompt")
    defer { state.cancelAnchor() }
    state.followToEnd()
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 0, "Do not visit the expanded prompt's stale end")
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 0)
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 765)
    state.settle()
    state.settle()
    XCTAssertTrue(state.tailSettled)
  }
}
