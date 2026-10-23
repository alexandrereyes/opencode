import XCTest

@MainActor final class VoicePickerTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func launch(active: Bool = false) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    if active { app.launchArguments += ["-OpenCodeVoiceBarFixture", "listening"] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Você"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Você"].tap()
    let row = app.buttons["settings-voice"]
    for _ in 0..<8 {
      if row.exists && row.isHittable && row.frame.maxY < app.tabBars.firstMatch.frame.minY - 70 { break }
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(row.isHittable)
    return app
  }
  private func shot(_ name: String) {
    let close = XCUIApplication().buttons["Fechar alerta"]
    if close.exists && close.isHittable {
      close.tap()
      XCTAssertTrue(close.waitForNonExistence(timeout: 3))
    }
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func assertVoice(_ name: String, app: XCUIApplication) {
    let row = app.buttons["settings-voice"]
    XCTAssertTrue((row.label + " " + (row.value as? String ?? "")).contains(name))
  }
  func testBrazilianOrderSelectionAndPersistenceInVoce() throws {
    let app = try launch()
    assertVoice("Rio", app: app)
    shot("settings-voice-rio")
    app.buttons["settings-voice"].tap()
    let rio = app.buttons["voice-choice-rio"]
    let viola = app.buttons["voice-choice-viola"]
    let cove = app.buttons["voice-choice-cove"]
    XCTAssertTrue(rio.waitForExistence(timeout: 5))
    XCTAssertTrue(rio.isSelected)
    XCTAssertTrue(app.staticTexts["Brasileiras"].exists)
    XCTAssertLessThan(rio.frame.minY, viola.frame.minY)
    XCTAssertLessThan(viola.frame.minY, cove.frame.minY)
    XCTAssertFalse(app.buttons["Ouvir"].exists)
    shot("voice-picker-rio")
    viola.tap()
    XCTAssertTrue(viola.isSelected)
    XCTAssertFalse(rio.isSelected)
    shot("voice-picker-viola")
    app.navigationBars["Voz"].buttons.firstMatch.tap()
    assertVoice("Viola", app: app)
    app.terminate()
    let restored = try launch()
    assertVoice("Viola", app: restored)
    restored.buttons["settings-voice"].tap()
    XCTAssertTrue(restored.buttons["voice-choice-viola"].isSelected)
    restored.buttons["voice-choice-rio"].tap()
    restored.terminate()
  }
  func testActiveCallNoteDoesNotRestartTheCall() throws {
    let app = try launch(active: true)
    let bar = app.descendants(matching: .any)["floating-voice-bar"].firstMatch
    XCTAssertTrue(bar.exists)
    XCTAssertTrue(app.staticTexts["Vale a partir da próxima chamada"].exists)
    shot("settings-voice-next-call")
    app.buttons["settings-voice"].tap()
    XCTAssertTrue(app.staticTexts["Vale a partir da próxima chamada"].waitForExistence(timeout: 5))
    app.buttons["voice-choice-viola"].tap()
    XCTAssertTrue(app.buttons["voice-choice-viola"].isSelected)
    XCTAssertTrue(bar.label.contains("ouvindo"))
    shot("voice-picker-next-call")
    app.buttons["voice-choice-rio"].tap()
    app.terminate()
  }
}
