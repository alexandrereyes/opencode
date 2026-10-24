import XCTest

@MainActor extension XCUIApplication {
  func revealSessionRow(_ row: XCUIElement) {
    XCTAssertTrue(navigationBars["Sessões"].waitForExistence(timeout: 10))
    let list = collectionViews.firstMatch
    let deadline = Date().addingTimeInterval(60)
    if !row.exists { list.swipeDown(velocity: .fast) }
    while Date() < deadline {
      let top = navigationBars.firstMatch.frame.maxY
      let bar = tabBars.firstMatch.frame
      let accessory = buttons["master-accessory"]
      let bottom = accessory.exists ? min(bar.minY, accessory.frame.minY) : bar.minY
      if row.exists {
        let frame = row.frame
        if frame.minY >= top && frame.maxY <= bottom && row.isHittable { return }
        if frame.minY < top {
          let start = coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.frame.midX, dy: top + 40))
          start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: min(160, top - frame.minY + 20))),
            withVelocity: .fast, thenHoldForDuration: 0.15)
          continue
        }
      }
      // A fast fling can skip an entire shorter row before AX mounts it.
      let start = coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.frame.midX, dy: bottom - 24))
      let end = coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.frame.midX, dy: top + 100))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.15)
    }
    XCTFail("A sessão não ficou visível acima da barra de abas.")
  }
}
