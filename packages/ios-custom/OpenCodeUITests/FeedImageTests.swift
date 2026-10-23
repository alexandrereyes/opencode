import XCTest

@MainActor final class FeedImageTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeOpenSession",
      try XCTUnwrap(environment["OPENCODE_IMAGE_" + role])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    return app
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "images-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testImageClassesAndFullscreen() throws {
    for role in ["RELATIVE", "ABSOLUTE", "TILDE", "FILE", "DATA", "HTML", "LOOPBACK", "ATTACHMENT", "HTTPS"] {
      let app = try launch(role)
      let image = app.buttons["feed-image-" + role]
      XCTAssertTrue(image.waitForExistence(timeout: 25), role)
      screenshot(role.lowercased())
      if role == "RELATIVE" {
        image.tap()
        XCTAssertTrue(app.navigationBars[role].waitForExistence(timeout: 5))
        screenshot("fullscreen")
        app.buttons["Fechar"].tap()
      }
      app.terminate()
    }
  }
  func testMissingAndMacOnlyURLsHaveHonestFailure() throws {
    for role in ["MISSING", "MACONLY", "INTERNAL"] {
      let app = try launch(role)
      XCTAssertTrue(app.staticTexts["Imagem indisponível no iPhone"].waitForExistence(timeout: 30))
      XCTAssertTrue(app.buttons["Tentar novamente"].exists)
      screenshot(role.lowercased())
      app.terminate()
    }
  }
  func testStoredToolImagesLoadOnExpansion() throws {
    for role in ["READ", "MCP"] {
      let app = try launch(role)
      let group = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Usou 1'")).firstMatch
      XCTAssertTrue(group.waitForExistence(timeout: 15))
      group.tap()
      let tool = app.buttons.matching(NSPredicate(format: role == "READ" ? "label BEGINSWITH 'Leu '" : "label BEGINSWITH 'browser_screenshot'")).firstMatch
      XCTAssertTrue(tool.waitForExistence(timeout: 5))
      tool.tap()
      XCTAssertTrue(app.buttons["feed-image-" + role].waitForExistence(timeout: 25))
      screenshot(role.lowercased())
      app.terminate()
    }
  }
}
