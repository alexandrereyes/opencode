import XCTest

@MainActor final class ConversationMenuTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testDetailsFirstTapDuringHeaderUpdates() {
    exercise(child: false, headerOnly: true)
    exercise(child: true, headerOnly: true)
  }

  func testDetailsFirstTapDuringTranscriptUpdates() {
    exercise(child: false, headerOnly: false)
    exercise(child: true, headerOnly: false)
  }

  private func exercise(child: Bool, headerOnly: Bool) {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
      "-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureMenuUpdates", "-OpenCodeMenuDiagnostics",
      "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    if child { app.launchArguments.append("-OpenCodeFixtureChild") }
    if headerOnly { app.launchArguments += ["-OpenCodeFixtureFollow", "-OpenCodeFixtureMenuHeaderOnly"] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 20))
    let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    for iteration in 0..<10 {
      app.buttons["Mais opções"].tap()
      if iteration == 0 {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "menu-updates-child-\(child)-headerOnly-\(headerOnly)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
      }
      app.buttons["Detalhes da sessão"].tap()
      XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 5))
      app.buttons["Fechar"].tap()
    }
    app.terminate()
  }
}
