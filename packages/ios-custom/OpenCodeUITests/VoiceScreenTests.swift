import XCTest

/// The screen fixture keeps the sandbox's real Sessão mestra and simulates GPT Live delegating with
/// `"screen": true` after a delay; no audio, proxy or GPT Live call.
@MainActor final class VoiceScreenUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
  private func launch(delay: Int) throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeVoiceScreenFixture",
      "-OpenCodeVoiceScreenDelay", String(delay)]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    try app.requireSandbox()
    return app
  }

  func testScreenOfTheOpenConversationReachesTheMaster() throws {
    let app = try launch(delay: 12)
    let id = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_VOICE_SESSION"])
    XCTAssertTrue(app.buttons["voice-start"].waitForExistence(timeout: 20))
    app.buttons["voice-start"].tap()
    let bar = app.descendants(matching: .any)["floating-voice-bar"]
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    let row = app.buttons["session-row-" + id]
    app.revealVoiceRow(row)
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    capture("screen-before-delegation")
    let outcome = app.staticTexts["voice-screen-outcome"]
    let sent = NSPredicate(format: "label BEGINSWITH 'sent:'")
    expectation(for: sent, evaluatedWith: outcome)
    waitForExpectations(timeout: 40)
    XCTAssertTrue(outcome.label.hasSuffix(":" + id), outcome.label)
    XCTAssertTrue(bar.exists, "the bar comes back after the capture")
    capture("screen-after-delegation")
    app.terminate()
  }

  func testOtherAppInFrontCapturesNothing() throws {
    let app = try launch(delay: 6)
    XCTAssertTrue(app.buttons["voice-start"].waitForExistence(timeout: 20))
    app.buttons["voice-start"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["floating-voice-bar"].waitForExistence(timeout: 5))
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 1))
    sleep(9)
    app.activate()
    let outcome = app.staticTexts["voice-screen-outcome"]
    XCTAssertTrue(outcome.waitForExistence(timeout: 10))
    XCTAssertEqual(outcome.label, "refused:background")
    capture("screen-refused-background")
    app.terminate()
  }
}
