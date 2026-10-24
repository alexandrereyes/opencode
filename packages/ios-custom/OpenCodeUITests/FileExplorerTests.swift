import XCTest

/// Requires `OPENCODE_EXPLORER_SESSION`, whose Location is the owned git checkout `OPENCODE_EXPLORER_ROOT`
/// (`script/test-file-explorer.py` prepares both).
@MainActor final class FileExplorerTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "explorer-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func expectPath(_ app: XCUIApplication, _ path: String) {
    let header = app.staticTexts["file-explorer-path"]
    let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", path), object: header)
    XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed, "explorer path")
  }

  func testBrowseAboveTheSessionAndOpenFiles() throws {
    let root = try XCTUnwrap(environment["OPENCODE_EXPLORER_ROOT"])
    let parent = (root as NSString).deletingLastPathComponent
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_EXPLORER_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    let directory = app.buttons["session-details-directory"]
    XCTAssertTrue(directory.waitForExistence(timeout: 10))
    XCTAssertTrue(directory.label.contains(root))
    screenshot("details")

    directory.tap()
    expectPath(app, root)
    // Like the web tree, listing includes dotfiles and directories come first.
    XCTAssertTrue(app.buttons["file-explorer-folder-.git"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["file-explorer-file-.env"].exists)
    XCTAssertLessThan(app.buttons["file-explorer-folder-src"].frame.minY, app.buttons["file-explorer-file-README.md"].frame.minY)
    screenshot("root")

    app.buttons["file-explorer-folder-src"].tap()
    expectPath(app, root + "/src")
    let main = app.buttons["file-explorer-file-main.swift"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertTrue(main.label.contains("Modificado"), main.label)
    screenshot("src")

    main.tap()
    XCTAssertTrue(app.navigationBars["main.swift"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.otherElements["file-preview"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'let b = 2'")).firstMatch.waitForExistence(timeout: 15))
    screenshot("viewer")
    app.navigationBars["main.swift"].buttons["Fechar"].tap()
    expectPath(app, root + "/src")

    app.buttons["file-explorer-up"].tap()
    expectPath(app, root)
    app.buttons["file-explorer-up"].tap()
    expectPath(app, parent)
    let name = (root as NSString).lastPathComponent
    XCTAssertTrue(app.buttons["file-explorer-folder-" + name].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["file-explorer-file-outside.txt"].exists)
    screenshot("above-root")

    app.buttons["file-explorer-file-outside.txt"].tap()
    XCTAssertTrue(app.navigationBars["outside.txt"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Fora da sessão'")).firstMatch.waitForExistence(timeout: 15))
    screenshot("viewer-outside")
    app.navigationBars["outside.txt"].buttons["Fechar"].tap()

    app.buttons["file-explorer-folder-" + name].tap()
    expectPath(app, root)
    app.buttons["file-explorer-folder-locked"].tap()
    expectPath(app, root + "/locked")
    XCTAssertTrue(app.descendants(matching: .any)["file-explorer-error"].waitForExistence(timeout: 10))
    screenshot("error")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    expectPath(app, root)

    let search = app.searchFields["Buscar arquivos"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("inner")
    let result = app.buttons["file-explorer-file-inner.txt"]
    XCTAssertTrue(result.waitForExistence(timeout: 15))
    XCTAssertTrue(result.label.contains("src/deep/inner.txt"), result.label)
    screenshot("search")
    result.tap()
    XCTAssertTrue(app.navigationBars["inner.txt"].waitForExistence(timeout: 20))
    app.navigationBars["inner.txt"].buttons["Fechar"].tap()
  }
}
