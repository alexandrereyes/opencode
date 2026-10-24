import XCTest

@MainActor final class SubscriptionTests: XCTestCase {
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(stub: String? = nil, largeText: Bool = false) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launchEnvironment["OPENCODE_PROXY_STUB"] = stub
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Você"].waitForExistence(timeout: 25))
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "proxy-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func open(_ app: XCUIApplication, provider: String = "codex") {
    app.tabBars.buttons["Você"].tap()
    let entry = app.buttons["proxy-settings-" + provider]
    XCTAssertTrue(entry.waitForExistence(timeout: 15))
    entry.tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.otherElements["proxy-pool-header"].waitForExistence(timeout: 20))
  }
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<20 {
      if element.exists && element.isHittable && element.frame.maxY < app.frame.maxY - 45 { return }
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(element.exists && element.isHittable)
  }
  func testLiveReadOnlyEntryPointsSelectionAndCancelledConfirmation() throws {
    let app = try launch()
    defer { app.terminate() }
    app.tabBars.buttons["Você"].tap()
    XCTAssertTrue(app.buttons["proxy-settings-anthropic"].waitForExistence(timeout: 20))
    shot("voce")
    app.buttons["proxy-settings-codex"].tap()
    XCTAssertTrue(app.otherElements["proxy-pool-header"].waitForExistence(timeout: 20))
    shot("codex")
    let reset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'proxy-reset-'" )).firstMatch
    reveal(reset, app: app)
    reset.tap()
    XCTAssertTrue(app.buttons["Cancelar"].waitForExistence(timeout: 5))
    shot("confirmation-cancelled")
    app.buttons["Cancelar"].tap()
    // Never confirm a real reset or automation change.
    app.segmentedControls["proxy-provider"].buttons["Claude"].tap()
    app.swipeDown(velocity: .slow)
    shot("claude")
    let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'proxy-select-'" )).firstMatch
    reveal(selection, app: app)
    let selectedID = selection.identifier
    selection.tap()
    XCTAssertTrue(app.buttons["proxy-close"].waitForNonExistence(timeout: 5))
    shot("voce-selected")
    app.tabBars.buttons["Sessões"].tap()
    shot("sessions-selected")
    app.buttons["proxy-strip-anthropic"].tap()
    XCTAssertTrue(app.segmentedControls["proxy-provider"].buttons["Claude"].isSelected)
    let selected = app.buttons[selectedID]
    reveal(selected, app: app)
    XCTAssertTrue(selected.isSelected)
    shot("account-selected")
    selected.tap()
  }
  func testStubbedConfirmedSuccessAndAutomation() throws {
    let app = try launch(stub: "success")
    defer { app.terminate() }
    open(app)
    let reset = app.buttons["proxy-reset-test-pro"]
    reveal(reset, app: app)
    reset.tap()
    app.alerts.buttons["Consumir redefinição"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["action-toast"].waitForExistence(timeout: 10))
    shot("stub-success")
    let automation = app.switches["proxy-automation"]
    reveal(automation, app: app)
    automation.tap()
    app.alerts.buttons["Cancelar"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: automation)], timeout: 10), .completed)
    automation.tap()
    XCTAssertTrue(app.buttons["Ativar"].waitForExistence(timeout: 5))
    app.alerts.buttons["Ativar"].firstMatch.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: automation)], timeout: 10), .completed)
    shot("stub-automation-success")
  }
  func testStubbedPendingAndError() throws {
    var app = try launch(stub: "pending")
    open(app)
    let reset = app.buttons["proxy-reset-test-pro"]
    reveal(reset, app: app)
    reset.tap()
    app.alerts.buttons["Consumir redefinição"].firstMatch.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: reset)], timeout: 5), .completed)
    shot("stub-pending")
    let pendingAutomation = app.switches["proxy-automation"]
    reveal(pendingAutomation, app: app)
    pendingAutomation.tap()
    app.alerts.buttons["Ativar"].firstMatch.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: pendingAutomation)], timeout: 5), .completed)
    shot("stub-automation-pending")
    app.terminate()
    app = try launch(stub: "error")
    defer { app.terminate() }
    open(app)
    reveal(app.buttons["proxy-reset-test-pro"], app: app)
    app.buttons["proxy-reset-test-pro"].tap()
    app.alerts.buttons["Consumir redefinição"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["action-toast"].waitForExistence(timeout: 10))
    shot("stub-error")
    _ = app.descendants(matching: .any)["action-toast"].waitForNonExistence(timeout: 8)
    let automation = app.switches["proxy-automation"]
    reveal(automation, app: app)
    automation.tap()
    app.alerts.buttons["Ativar"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["action-toast"].waitForExistence(timeout: 10))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: automation)], timeout: 10), .completed)
    shot("stub-automation-error")
  }
  func testStubbedUnavailableUnconfiguredAndAccessibleAccountActions() throws {
    for (scenario, title) in [("unavailable", "LLM proxy indisponível"), ("unconfigured", "LLM proxy não configurado")] {
      let app = try launch(stub: scenario)
      app.tabBars.buttons["Você"].tap()
      app.buttons["proxy-settings-codex"].tap()
      XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
      shot("stub-" + scenario)
      app.terminate()
    }
    let app = try launch(stub: "success", largeText: true)
    defer { app.terminate() }
    open(app)
    let reset = app.buttons["proxy-reset-test-pro"]
    reveal(reset, app: app)
    XCTAssertTrue(app.buttons["proxy-select-test-pro"].exists)
    shot("stub-accessible-actions")
    reset.tap()
    XCTAssertTrue(app.alerts.buttons["Cancelar"].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancelar"].tap()
  }
}
