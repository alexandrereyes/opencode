import XCTest

@MainActor final class VoiceUITests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
  func testFloatingVoiceSurvivesNavigationAndControls() throws {
    let environment = ProcessInfo.processInfo.environment
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeVoiceFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let start = app.buttons["voice-start"]
    XCTAssertTrue(start.waitForExistence(timeout: 20))
    start.tap()
    let bar = app.descendants(matching: .any)["floating-voice-bar"]
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    XCTAssertTrue(bar.label.hasPrefix("Conversa por voz"))
    XCTAssertFalse(app.buttons["master-accessory"].exists)
    bar.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 28)).tap()
    capture("voice-sessions")
    let id = try XCTUnwrap(environment["OPENCODE_VOICE_SESSION"])
    let row = app.buttons["session-row-" + id]
    app.revealVoiceRow(row)
    XCTAssertTrue(row.exists)
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    XCTAssertTrue(bar.exists)
    XCTAssertLessThanOrEqual(bar.frame.maxY, app.textViews["conversation-composer"].frame.minY)
    capture("voice-conversation")
    app.buttons["Voltar"].tap()
    app.tabBars.buttons["Você"].tap()
    XCTAssertTrue(bar.exists)
    bar.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
      .withOffset(CGVector(dx: -86, dy: 29)).tap()
    XCTAssertTrue(bar.label.contains("microfone desligado"))
    capture("voice-settings-muted")
    bar.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
      .withOffset(CGVector(dx: -36, dy: 29)).tap()
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["master-accessory"].waitForExistence(timeout: 5))
    app.terminate()
  }
}
