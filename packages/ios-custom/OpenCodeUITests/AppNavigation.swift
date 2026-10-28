import XCTest

/// The app has no tab bar: Sessões is the root and Você is a sheet opened from its header avatar.
@MainActor extension XCUIApplication {
  /// The Sessões header avatar that opens Você.
  var accountButton: XCUIElement { buttons["sessions-account"] }

  /// Opens Você from the Sessões root, leaving any conversation first.
  func openYou(file: StaticString = #filePath, line: UInt = #line) {
    showSessions(file: file, line: line)
    XCTAssertTrue(accountButton.waitForExistence(timeout: 20), file: file, line: line)
    accountButton.tap()
    // XCUITest waits for running arcs to idle before the sheet animates in.
    XCTAssertTrue(navigationBars["Você"].waitForExistence(timeout: 20), file: file, line: line)
  }

  /// Back to the Sessões root, as tapping its tab did: closes Você (and screens pushed in it) and pops the
  /// conversation stack.
  func showSessions(file: StaticString = #filePath, line: UInt = #line) {
    let close = buttons["settings-close"]
    let back = buttons["Voltar"].firstMatch
    for _ in 0..<10 {
      if close.exists && close.isHittable {
        close.tap()
        _ = close.waitForNonExistence(timeout: 5)
      } else if navigationBars.buttons["Você"].exists {
        // A screen pushed inside Você: its back button is titled after it.
        navigationBars.buttons["Você"].tap()
      } else if sessionsTitle.exists && sessionsTitle.isHittable {
        return
      } else if back.exists && back.isHittable {
        back.tap()
        _ = sessionsTitle.waitForExistence(timeout: 2)
      } else if !sessionsTitle.waitForExistence(timeout: 2) {
        break
      }
    }
    XCTAssertTrue(sessionsTitle.waitForExistence(timeout: 10), file: file, line: line)
  }

  /// The top of the bottom chrome on Sessões: the Sessão mestra bar, else the home indicator's area.
  var bottomChromeTop: CGFloat {
    let master = buttons["master-accessory"]
    return master.exists ? master.frame.minY : frame.maxY - 34
  }
}
