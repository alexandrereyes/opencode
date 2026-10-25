import UIKit
import XCTest

@testable import OpenCode

@MainActor final class UserPromptTests: XCTestCase {
  func testTapToExpandKeepsThePromptAStaticTextElement() {
    let view = UserPromptScrollView()
    XCTAssertTrue(view.label.isAccessibilityElement)
    XCTAssertTrue(view.label.accessibilityTraits.contains(.staticText))
    XCTAssertFalse(view.label.accessibilityTraits.contains(.button))
  }

  func testPinnedPromptOffersVoiceOverJumpToTheStartOfTheAnswer() throws {
    let view = UserPromptScrollView()
    XCTAssertNil(view.label.accessibilityCustomActions)
    var pinned = false
    view.jump = { pinned }
    let action = try XCTUnwrap(view.label.accessibilityCustomActions?.first)
    XCTAssertEqual(action.name, "Ir para o começo da resposta")
    XCTAssertFalse(action.actionHandler?(action) ?? true)
    pinned = true
    XCTAssertTrue(action.actionHandler?(action) ?? false)
    view.jump = nil
    XCTAssertNil(view.label.accessibilityCustomActions)
  }

  func testMeasuredTwoLineThresholdPreservesNewlinesAndInternalScrolling() {
    let view = UserPromptScrollView()
    view.label.text = "Primeira linha\nSegunda linha"
    let two = view.measure(width: 320, maximumHeight: 120)
    XCTAssertEqual(two.height, ceil(view.label.font.lineHeight * 2), accuracy: 1)
    view.label.text = "Primeira linha\nSegunda linha\nTerceira linha"
    view.measurements.removeAll()
    let three = view.measure(width: 320, maximumHeight: 120)
    XCTAssertEqual(three.height, two.height)
    XCTAssertEqual(view.label.text, "Primeira linha\nSegunda linha\nTerceira linha")
    view.collapsed = false
    let expanded = view.measure(width: 320, maximumHeight: 120)
    XCTAssertGreaterThan(expanded.height, three.height)
    XCTAssertFalse(view.isScrollEnabled)
    view.label.text = Array(repeating: "Linha preservada", count: 40).joined(separator: "\n")
    view.measurements.removeAll()
    let bounded = view.measure(width: 320, maximumHeight: 120)
    XCTAssertEqual(bounded.height, 120)
    XCTAssertTrue(view.isScrollEnabled)
    XCTAssertGreaterThan(view.contentSize.height, 120)
    view.collapsed = true
    XCTAssertEqual(view.measure(width: 320, maximumHeight: 120).height, two.height)
    XCTAssertFalse(view.isScrollEnabled)
    XCTAssertEqual(view.contentOffset, .zero)
  }

  func testMeasurementRespondsToWidthNotScrollOffset() {
    let view = UserPromptScrollView()
    view.label.text = String(repeating: "Mensagem longa com palavras. ", count: 20)
    let wide = view.measure(width: 320, maximumHeight: 300)
    view.contentOffset.y = 100
    XCTAssertEqual(view.measure(width: 320, maximumHeight: 300), wide)
    view.collapsed = false
    let expanded = view.measure(width: 320, maximumHeight: 1000)
    XCTAssertGreaterThan(view.measure(width: 160, maximumHeight: 1000).height, expanded.height)
  }

  func testSearchRangeRemainsVisibleWhenTheViewportShrinks() {
    let view = UserPromptScrollView()
    let text = Array(repeating: "Linha de contexto.", count: 40).joined(separator: "\n") + "\nResultado final."
    view.label.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
    view.collapsed = false
    view.revealRange = (text as NSString).range(of: "Resultado final.")
    view.frame = CGRect(origin: .zero, size: view.measure(width: 300, maximumHeight: 180))
    view.layoutIfNeeded()
    XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 2)
    view.frame = CGRect(origin: .zero, size: view.measure(width: 300, maximumHeight: 90))
    view.layoutIfNeeded()
    XCTAssertEqual(view.contentOffset.y, view.contentSize.height - view.bounds.height, accuracy: 2)
  }
}
