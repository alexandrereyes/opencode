import XCTest

/// Sessões is the root without a tab bar: the header avatar opens Você and the Sessão mestra bar sits where the tab
/// bar was, without covering the list's last row. Needs any isolated sandbox with sessions; sends nothing.
@MainActor final class AppShellTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testNoTabBarAvatarOpensYouAndMasterBarLeavesTheLastRowVisible() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))
    try app.requireSandbox()

    // No tab bar and none of its placeholder screens.
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    for name in ["Painel", "Pedidos", "Projetos"] { XCTAssertFalse(app.buttons[name].exists, name) }
    // Header: voice, then +, then the Você avatar, on the title's line.
    let voice = app.buttons["voice-start"]
    let add = app.buttons["Nova sessão"]
    let account = app.accountButton
    XCTAssertTrue(account.waitForExistence(timeout: 10))
    XCTAssertEqual(account.label, "Você")
    XCTAssertTrue(voice.frame.maxX <= add.frame.minX && add.frame.maxX <= account.frame.minX)
    XCTAssertEqual(account.frame.midY, app.sessionsTitle.frame.midY, accuracy: 12)
    XCTAssertLessThanOrEqual(account.frame.maxX, app.frame.maxX)

    // The Sessão mestra bar sits above the home indicator, where the tab bar was.
    let master = app.buttons["master-accessory"]
    XCTAssertTrue(master.waitForExistence(timeout: 20))
    XCTAssertGreaterThanOrEqual(master.frame.maxY, app.frame.maxY - 60)
    XCTAssertLessThanOrEqual(master.frame.maxY, app.frame.maxY - 20)
    shot("shell-sessions")

    // The avatar opens Você; its close button and a swipe down both return to Sessões.
    account.tap()
    // XCUITest waits for the running arcs to idle before the sheet animates in.
    XCTAssertTrue(app.navigationBars["Você"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["settings-themes"].firstMatch.waitForExistence(timeout: 5))
    shot("shell-you")
    app.buttons["settings-close"].tap()
    XCTAssertTrue(app.navigationBars["Você"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(account.isHittable)
    account.tap()
    XCTAssertTrue(app.navigationBars["Você"].waitForExistence(timeout: 20))
    app.navigationBars["Você"].swipeDown(velocity: .fast)
    XCTAssertTrue(app.navigationBars["Você"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.sessionsTitle.isHittable)

    // At the end of the list, its last row (Arquivadas) stays above the bar, not behind it.
    let last = app.buttons["sessions-archived"]
    let list = app.collectionViews.firstMatch
    for _ in 0..<15 where !(last.exists && last.isHittable && last.frame.maxY <= master.frame.minY) {
      list.swipeUp(velocity: .fast)
    }
    list.swipeUp(velocity: .fast)
    XCTAssertTrue(last.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(last.frame.maxY, master.frame.minY + 1, "Arquivadas sob a faixa da Sessão mestra")
    XCTAssertTrue(last.isHittable)
    shot("shell-list-end")

    // The bar opens the Sessão mestra and returns with the conversation's back button.
    master.tap()
    XCTAssertTrue(app.buttons["Voltar"].firstMatch.waitForExistence(timeout: 20))
    XCTAssertFalse(master.exists)
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(master.waitForExistence(timeout: 10))
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 10))
  }

  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
