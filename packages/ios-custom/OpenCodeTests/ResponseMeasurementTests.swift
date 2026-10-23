import OpenCodeKit
import SwiftUI
import UIKit
import XCTest

@testable import OpenCode

@MainActor final class ResponseMeasurementTests: XCTestCase {
  func testMarkdownCacheSeparatesVersionsAndPreservesSelectionOffsets() async throws {
    let cache = ResponseMarkdownCache()
    let source = "# Título\n\nTexto com **ênfase** e `código`."
    XCTAssertNil(cache.cached(source))
    let blocks = await cache.parse(source)
    XCTAssertEqual(cache.cached(source), blocks)
    let repeated = await cache.parse(source)
    XCTAssertEqual(repeated, blocks)
    XCTAssertNil(cache.cached(source + " alterado"))
    XCTAssertEqual(blocks, MarkdownBlocks.parse(source))
  }
  func testTextMeasurementCachesEachWidthAndInvalidatesChangedText() {
    let view = ResponseTextView(frame: .zero, textContainer: nil)
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.attributedText = NSAttributedString(
      string: String(repeating: "Texto sintético com código e ferramentas. ", count: 30),
      attributes: [.font: UIFont.systemFont(ofSize: 16)])
    let first = view.fittingSize(width: 300)
    XCTAssertEqual(view.fittingSize(width: 300), first)
    XCTAssertEqual(view.measuredSizes.count, 1)
    XCTAssertGreaterThan(view.fittingSize(width: 200).height, first.height)
    XCTAssertEqual(view.measuredSizes.count, 2)
    view.attributedText = NSAttributedString(string: "Curto", attributes: [.font: UIFont.systemFont(ofSize: 16)])
    XCTAssertTrue(view.measuredSizes.isEmpty)
    XCTAssertLessThan(view.fittingSize(width: 300).height, first.height)
  }

  func testTextMeasurementInvalidatesWhenDynamicTypeChanges() async throws {
    let block = try XCTUnwrap(MarkdownBlocks.parse(String(repeating: "Texto com palavras e **ênfase**. ", count: 15)).first)
    let window = UIWindow(windowScene: try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
    let host = UIHostingController(rootView:
      SelectableResponseText(block: block, messageID: "message", partID: "part", theme: .selected)
        .environment(\.dynamicTypeSize, .large))
    window.rootViewController = host
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    defer { window.isHidden = true; window.rootViewController = nil }
    func response(in parent: UIView) -> ResponseTextView? {
      (parent as? ResponseTextView) ?? parent.subviews.lazy.compactMap { response(in: $0) }.first
    }
    let view = try XCTUnwrap(response(in: host.view))
    let first = view.fittingSize(width: 300)
    host.rootView = SelectableResponseText(block: block, messageID: "message", partID: "part", theme: .selected)
      .environment(\.dynamicTypeSize, .accessibility5)
    await fulfillment(of: [expectation(for: NSPredicate { _, _ in
      view.fittingSize(width: 300).height > first.height
    }, evaluatedWith: nil)], timeout: 5)
    XCTAssertGreaterThan(view.fittingSize(width: 300).height, first.height)
  }

}
