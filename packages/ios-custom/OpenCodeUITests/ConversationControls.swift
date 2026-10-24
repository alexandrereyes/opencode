import XCTest

@MainActor extension XCUIApplication {
  func openConversationOptions(expect title: String) -> XCUIElement {
    let menu = buttons["Mais opções"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: menu)], timeout: 10), .completed)
    menu.tap()
    let action = buttons[title]
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    return action
  }
}
