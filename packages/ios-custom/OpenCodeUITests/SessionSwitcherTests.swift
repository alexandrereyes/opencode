import XCTest

/// Needs the seed-sessions sandbox (running "Redesign") and an unread root titled `OPENCODE_TEST_SWITCH_UNREAD`.
/// `OPENCODE_TEST_SWITCH_FROM`/`_TO` are root session IDs, `OPENCODE_TEST_SWITCH_TO_TITLE` the target's title and
/// `OPENCODE_TEST_SWITCH_PROJECT` its project. Sends nothing.
@MainActor final class SessionSwitcherTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testHeaderSwitcherListsSearchesSwitchesInPlaceAndStartsNewSession() throws {
    continueAfterFailure = false
    let from = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_FROM"])
    let to = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_TO"])
    let toTitle = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_TO_TITLE"])
    let project = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_PROJECT"])
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenSession", from,
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }

    // The avatar and title open the switcher, with the current session marked and visible.
    let trigger = app.buttons["conversation-switcher"]
    XCTAssertTrue(trigger.waitForExistence(timeout: 30))
    // "Nova sessão" creates a session: act only on the sandbox.
    try app.requireSandbox()
    XCTAssertEqual(trigger.label, "Trocar de sessão")
    trigger.tap()
    let current = app.buttons["switcher-row-" + from]
    XCTAssertTrue(current.waitForExistence(timeout: 10))
    XCTAssertTrue(current.isSelected)
    XCTAssertTrue(current.isHittable)
    shot("switcher-open")

    // Local search by title; running and unread rows keep the Sessões presentation.
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'switcher-row-'"))
    let search = app.searchFields["Buscar sessão"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Redesign")
    XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS ', trabalhando'")).firstMatch.waitForExistence(timeout: 10))
    shot("switcher-running")
    clear(search)
    search.typeText(try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_UNREAD"]))
    XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS ', não lida'")).firstMatch.waitForExistence(timeout: 10))
    clear(search)
    search.typeText(String(toTitle.prefix(6)))
    let target = app.buttons["switcher-row-" + to]
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    XCTAssertTrue(current.waitForNonExistence(timeout: 5))
    shot("switcher-search")

    // Choosing replaces the conversation in place; Back returns to Sessões.
    target.tap()
    let title = app.staticTexts["conversation-header-title"]
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", toTitle), object: title)],
        timeout: 20), .completed)
    shot("switcher-switched")

    // Tapping the current session only closes the sheet.
    trigger.tap()
    let now = app.buttons["switcher-row-" + to]
    XCTAssertTrue(now.waitForExistence(timeout: 10))
    XCTAssertTrue(now.isSelected)
    now.tap()
    XCTAssertTrue(now.waitForNonExistence(timeout: 10))
    XCTAssertEqual(title.label, toTitle)

    // Nova sessão from the switcher inherits the current project.
    trigger.tap()
    let create = app.buttons["switcher-new-session"]
    XCTAssertTrue(create.waitForExistence(timeout: 10))
    create.tap()
    let location = app.buttons["new-project"]
    XCTAssertTrue(location.waitForExistence(timeout: 20))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", project), object: location)],
        timeout: 20), .completed)
    shot("switcher-new-session")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", toTitle), object: title)],
        timeout: 20), .completed)
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(title.waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 10))
  }

  private func clear(_ field: XCUIElement) {
    let value = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count + 2))
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
