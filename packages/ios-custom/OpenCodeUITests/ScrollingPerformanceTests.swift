import XCTest

@MainActor final class ScrollingPerformanceTests: XCTestCase {
  private func launch(_ mode: String, updates: Bool, theme: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177",
      "-OpenCodeScrollFixture", mode, "-OpenCodeFixturePosition", "middle",
      "-OpenCodeTheme", theme ?? ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"]
    if updates { app.launchArguments.append("-OpenCodeFixtureUpdates") }
    app.launch()
    return app
  }

  private func scroll(_ mode: String, updates: Bool = false) {
    let app = launch(mode, updates: updates)
    let list = mode == "conversation"
      ? app.collectionViews["conversation-transcript"] : app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 20))
    if mode == "conversation" {
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: list)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }
    let options = XCTMeasureOptions()
    options.iterationCount = 5
    measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)], options: options) {
      list.swipeUp(velocity: .fast)
      list.swipeUp(velocity: .fast)
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "scroll-fixture-" + mode
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.terminate()
  }

  func testConversationScrolling() { scroll("conversation") }
  func testInvalidFixtureArgumentNeverFallsBackToServer() {
    let app = launch("invalid", updates: false)
    XCTAssertTrue(app.staticTexts["Fixture desconhecida"].waitForExistence(timeout: 10))
    app.terminate()
  }
  func testFixtureHistoryJumpInBothThemes() {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = launch("conversation", updates: false, theme: theme)
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      XCTAssertTrue(app.buttons["Ir para a mais recente"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["Ir às novas mensagens"].exists)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "fixture-history-jump-" + theme
      screenshot.lifetime = .keepAlways
      add(screenshot)
      app.terminate()
    }
  }
  func testSessionsScrolling() { scroll("sessions") }
  func testSessionsWithPreviewUpdatesScrolling() { scroll("sessions", updates: true) }
}
