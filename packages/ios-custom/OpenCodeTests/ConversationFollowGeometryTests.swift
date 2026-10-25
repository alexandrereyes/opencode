import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ConversationFollowGeometryTests: XCTestCase {
  private final class Scroll: UIScrollView {
    var simulatedDeceleration = false
    override var isDecelerating: Bool { simulatedDeceleration }
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

  func testPinnedPromptBringsItsTurnBelowItOnce() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    let scroll = Scroll(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.contentSize = CGSize(width: 400, height: 5000)
    let header = UICollectionReusableView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    let headerProbe = UIView(frame: .zero)
    header.addSubview(headerProbe)
    let row = UICollectionViewCell(frame: CGRect(x: 0, y: 1000, width: 400, height: 200))
    let rowProbe = UIView(frame: .zero)
    row.contentView.addSubview(rowProbe)
    scroll.addSubview(row)
    scroll.addSubview(header)
    window.rootViewController?.view.addSubview(scroll)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let state = ConversationScrollState()
    state.view = scroll
    state.register(rowProbe, id: "turn")
    state.registerHeader(headerProbe, container: header, id: "prompt")
    defer { state.cancelAnchor() }
    // Inline, the prompt keeps its own taps.
    XCTAssertEqual(state.revealTurn(prompt: "prompt", row: "turn"), .unpinned)
    // Pinned 1600 points below the row's start: one viewport away, then a single animation.
    scroll.contentOffset.y = 2500
    header.frame.origin.y = 2500
    XCTAssertEqual(state.revealTurn(prompt: "prompt", row: "turn"), .scrolled)
    XCTAssertEqual(scroll.contentOffset.y, 1400, accuracy: 0.5)
    XCTAssertTrue(state.touching)
    XCTAssertEqual(state.revealTurn(prompt: "prompt", row: "turn"), .repeated)
    header.frame.origin.y = 900
    let deadline = Date().addingTimeInterval(2)
    while state.touching && Date() < deadline { try await Task.sleep(for: .milliseconds(16)) }
    XCTAssertFalse(state.touching)
    XCTAssertEqual(scroll.contentOffset.y, 900, accuracy: 0.5)
    XCTAssertEqual(state.readingAnchor?.id, "turn")
    XCTAssertEqual(state.readingAnchor?.viewportTop ?? 0, 100, accuracy: 0.5)
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(state.revealTurn(prompt: "prompt", row: "turn"), .settled)
    XCTAssertEqual(scroll.contentOffset.y, 900, accuracy: 0.5)
  }

  func testFollowingDoesNotResizeThePinnedPrompt() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIViewController()
    let scroll = Scroll(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.contentSize = CGSize(width: 400, height: 1400)
    let cell = UICollectionReusableView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
    let header = UIView(frame: .zero)
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
    XCTAssertEqual(scroll.contentOffset.y, 0)
    state.settle()
    XCTAssertEqual(scroll.contentOffset.y, 800)
    XCTAssertEqual(scroll.contentSize.height, 1400)
    XCTAssertEqual(cell.bounds.height, 100)
    state.settle()
    state.settle()
    XCTAssertTrue(state.tailSettled)
  }
}
