import XCTest

/// Needs the seed-sessions sandbox (running "Redesign") and an unread root titled `OPENCODE_TEST_SWITCH_UNREAD`.
/// `OPENCODE_TEST_SWITCH_FROM`/`_TO` are root session IDs, `OPENCODE_TEST_SWITCH_TO_TITLE` the target's title and
/// `OPENCODE_TEST_SWITCH_PROJECT` its project. Sends nothing.
@MainActor final class SessionSwitcherTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testSwitchingBackRestoresBothRetainedPassages() throws {
    continueAfterFailure = false
    let from = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_FROM"])
    let to = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_TO"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenSession", from]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 30))
    try app.requireSandbox()
    let fromTitle = app.staticTexts["conversation-header-title"].label
    let toTitle = try XCTUnwrap(environment["OPENCODE_TEST_SWITCH_TO_TITLE"])

    @MainActor func place() throws -> (id: String, y: CGFloat) {
      transcript.swipeDown(velocity: .slow)
      transcript.swipeDown(velocity: .slow)
      let cell = try XCTUnwrap(transcript.cells.allElementsBoundByIndex.first {
        $0.identifier.hasPrefix("text:") && $0.frame.minY > transcript.frame.minY + 100
          && $0.frame.minY < transcript.frame.maxY - 50
      })
      return (cell.identifier, cell.frame.minY)
    }
    @MainActor func choose(_ id: String, title: String) {
      app.buttons["conversation-switcher"].tap()
      let search = app.textFields["switcher-search"]
      XCTAssertTrue(search.waitForExistence(timeout: 10))
      search.tap()
      search.typeText(title)
      let row = app.buttons["switcher-row-" + id]
      XCTAssertTrue(row.waitForExistence(timeout: 10))
      row.tap()
      XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label == %@", title), object: app.staticTexts["conversation-header-title"])],
        timeout: 20), .completed)
      XCTAssertTrue(transcript.waitForExistence(timeout: 10))
      XCTAssertNotEqual(transcript.value as? String, "Restaurando leitura")
    }

    let first = try place()
    choose(to, title: toTitle)
    let second = try place()
    choose(from, title: fromTitle)
    XCTAssertEqual(transcript.cells[first.id].frame.minY, first.y, accuracy: 0.5)
    shot("switcher-retained-origin")
    choose(to, title: toTitle)
    XCTAssertEqual(transcript.cells[second.id].frame.minY, second.y, accuracy: 0.5)
    shot("switcher-retained-target")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 10))
  }

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

    // The picker opens at the top. Searching for the current session still finds its selected marker.
    let trigger = app.buttons["conversation-switcher"]
    XCTAssertTrue(trigger.waitForExistence(timeout: 30))
    // "Nova sessão" creates a session: act only on the sandbox.
    try app.requireSandbox()
    XCTAssertEqual(trigger.label, "Trocar de sessão")
    let fromTitle = app.staticTexts["conversation-header-title"].label
    trigger.tap()
    let search = app.textFields["switcher-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["switcher-new-session"].isHittable)
    shot("switcher-open")
    search.tap()
    search.typeText(fromTitle)
    let current = app.buttons["switcher-row-" + from]
    XCTAssertTrue(current.waitForExistence(timeout: 10))
    XCTAssertTrue(current.isSelected)
    XCTAssertTrue(current.isHittable)
    clear(search)

    // Local search by title; running and unread rows keep the Sessões presentation.
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'switcher-row-'"))
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
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText(toTitle)
    let now = app.buttons["switcher-row-" + to]
    XCTAssertTrue(now.waitForExistence(timeout: 10))
    XCTAssertTrue(now.isSelected)
    now.tap()
    XCTAssertTrue(now.waitForNonExistence(timeout: 10))
    XCTAssertEqual(title.label, toTitle)

    // Nova sessão from the switcher inherits the current project.
    trigger.tap()
    let projectChip = app.buttons.matching(identifier: "filter-project-" + project).allElementsBoundByIndex.last!
    XCTAssertTrue(projectChip.waitForExistence(timeout: 10))
    let strip = app.scrollViews.containing(.button, identifier: "filter-chats").allElementsBoundByIndex.last!
    for _ in 0..<6 where !projectChip.isHittable { strip.swipeLeft() }
    projectChip.tap()
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

  func testCatalogChipsGroupingSearchAndCreation() throws {
    let app = catalog()
    defer { app.terminate() }
    let list = app.collectionViews["session-switcher-list"]
    XCTAssertTrue(list.waitForExistence(timeout: 10))
    let current = list.buttons["switcher-row-ses_scroll_0000"]
    XCTAssertTrue(list.buttons["session-section-attention"].isHittable)
    XCTAssertTrue(list.buttons["switcher-row-ses_scroll_0001"].exists, "Todas includes ordinary chats")
    XCTAssertTrue(app.buttons["switcher-new-session"].isHittable)
    XCTAssertFalse(list.buttons["sessions-archived"].exists, "the empty archive is absent from the picker")
    shot("switcher-open")

    // Filter and search combine; the title matches a different project, so there must be no row.
    app.buttons.matching(identifier: "filter-project-Projeto Exemplo 0").allElementsBoundByIndex.last!.tap()
    XCTAssertTrue(current.waitForExistence(timeout: 5))
    XCTAssertTrue(current.isSelected)
    let search = app.textFields["switcher-search"]
    search.tap()
    search.typeText("contraste")
    XCTAssertTrue(list.buttons["switcher-row-ses_scroll_0008"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Nenhuma sessão"].waitForExistence(timeout: 5))
    clear(search)
    search.typeText("navegação")
    XCTAssertTrue(current.waitForExistence(timeout: 5))
    XCTAssertFalse(list.buttons["sessions-archived"].exists, "search results contain sessions only")
    shot("switcher-search")
    app.buttons["Limpar busca"].tap()

    // The header action is always reachable and uses the sheet's chip, not the originating conversation.
    app.buttons.matching(identifier: "filter-chats").allElementsBoundByIndex.last!.tap()
    XCTAssertTrue(list.buttons["switcher-row-ses_scroll_0001"].waitForExistence(timeout: 5))
    app.buttons["switcher-new-session"].tap()
    let project = app.buttons["new-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 15))
    XCTAssertTrue(project.label.contains("Chats"), project.label)
    app.buttons["Voltar"].firstMatch.tap()
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(app.buttons["filter-all"].firstMatch.isSelected, "sheet filters do not change the tab")
  }

  func testCatalogCompletionWaitsForSwitcherGesture() {
    let app = catalog(updates: true)
    defer { app.terminate() }
    let list = app.collectionViews["session-switcher-list"]
    XCTAssertTrue(list.waitForExistence(timeout: 10))
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.65))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80)),
      withVelocity: .slow, thenHoldForDuration: 1)
    let report = app.staticTexts.matching(identifier: "session-list-fixture-report").allElementsBoundByIndex.last!
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == 'held=true applied=true running=false shift=0.0'"), object: report)], timeout: 10), .completed)
  }

  func testCatalogAlwaysReopensAtTopAfterScrollingAndFiltering() {
    let app = catalog(current: "ses_scroll_0008")
    defer { app.terminate() }
    let list = app.collectionViews["session-switcher-list"]
    let search = app.textFields["switcher-search"]
    let first = list.buttons["session-section-attention"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertTrue(first.isHittable)
    let top = first.frame.minY
    XCTAssertGreaterThanOrEqual(top, search.frame.maxY)
    XCTAssertLessThan(top - search.frame.maxY, 60)

    list.swipeUp(velocity: .slow)
    XCTAssertFalse(first.isHittable)
    app.buttons["switcher-close"].tap()
    app.buttons["conversation-switcher"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertEqual(first.frame.minY, top, accuracy: 1)

    // A chip change and a query change both start their results at the top.
    list.swipeUp(velocity: .slow)
    app.buttons.matching(identifier: "filter-project-Projeto Exemplo 0").allElementsBoundByIndex.last!.tap()
    let running = list.buttons["session-section-running"]
    XCTAssertTrue(running.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(running.frame.minY, search.frame.maxY)
    XCTAssertLessThan(running.frame.minY - search.frame.maxY, 60)
    app.buttons.matching(identifier: "filter-all").allElementsBoundByIndex.last!.tap()
    list.swipeUp(velocity: .slow)
    search.tap()
    search.typeText("contraste")
    let week = list.buttons["session-section-week"]
    XCTAssertTrue(week.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(week.frame.minY, search.frame.maxY)
    XCTAssertLessThan(week.frame.minY - search.frame.maxY, 60)
    let current = list.buttons["switcher-row-ses_scroll_0008"]
    XCTAssertTrue(current.isSelected)

    app.buttons["switcher-close"].tap()
    app.buttons["conversation-switcher"].tap()
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertEqual(first.frame.minY, top, accuracy: 1)
    XCTAssertEqual(search.value as? String, "Buscar sessão")
    shot("switcher-reopened-top")
  }

  private func catalog(updates: Bool = false, current: String = "ses_scroll_0000") -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "catalog", "-OpenCodeSessionSections", "{}"]
    if updates { app.launchArguments.append("-OpenCodeSessionListUpdates") }
    else { app.launchArguments.append("-OpenCodeCatalogSections") }
    app.launch()
    let row = app.buttons["session-row-" + current]
    XCTAssertTrue(app.buttons["session-row-ses_scroll_0000"].waitForExistence(timeout: 20))
    if !updates { app.revealSessionRow(row) }
    row.tap()
    XCTAssertTrue(app.buttons["conversation-switcher"].waitForExistence(timeout: 15))
    app.buttons["conversation-switcher"].tap()
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
