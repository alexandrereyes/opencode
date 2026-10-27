import XCTest

@MainActor extension XCUIApplication {
  /// The Sessões column header's title; the screen has no navigation bar.
  var sessionsTitle: XCUIElement { staticTexts["sessions-title"] }
  /// The lowest edge of the header (title and buttons) plus its soft fade, above which rows are covered.
  var sessionsTop: CGFloat { max(sessionsTitle.frame.maxY, buttons["voice-start"].frame.maxY) + 16 }
  func revealSessionRow(_ row: XCUIElement) {
    XCTAssertTrue(sessionsTitle.waitForExistence(timeout: 10))
    let list = collectionViews.firstMatch
    let deadline = Date().addingTimeInterval(60)
    if !row.exists { list.swipeDown(velocity: .fast) }
    while Date() < deadline {
      let top = sessionsTop
      let bar = tabBars.firstMatch.frame
      let accessory = buttons["master-accessory"]
      let bottom = accessory.exists ? min(bar.minY, accessory.frame.minY) : bar.minY
      // Rows older than seven days start inside the collapsed "Anteriores".
      let older = buttons["session-section-older"]
      if !row.exists, older.exists, older.isHittable, older.frame.minY >= top, older.frame.maxY <= bottom,
        older.value as? String == "recolhida"
      {
        older.tap()
        continue
      }
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
