import XCTest

@MainActor extension XCUIApplication {
  func revealVoiceRow(_ row: XCUIElement) {
    XCTAssertTrue(navigationBars["Sessões"].waitForExistence(timeout: 10))
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      let top = navigationBars.firstMatch.frame.maxY
      let bottom = descendants(matching: .any)["floating-voice-bar"].frame.minY
      if row.exists {
        let frame = row.frame
        if frame.height > 0, frame.minY >= top, frame.maxY <= bottom - 4 { return }
        if frame.minY < top { scrollVoiceList(from: top + 40, to: top + min(180, top - frame.minY + 60)); continue }
      }
      scrollVoiceList(from: bottom - 30, to: top + 100)
    }
    XCTFail("A sessão não ficou visível acima da faixa de voz")
  }
  private func scrollVoiceList(from: CGFloat, to: CGFloat) {
    let origin = coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: frame.midX, dy: from)).press(forDuration: 0.05,
      thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: to)),
      withVelocity: .fast, thenHoldForDuration: 0.2)
  }
}
