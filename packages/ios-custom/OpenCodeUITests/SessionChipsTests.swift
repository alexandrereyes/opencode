import XCTest

/// Prepared by `script/test-session-chips.py`: nothing runs, every root session is read except one in each of two
/// repositories. `OPENCODE_TEST_CHIP_MANUAL` is the saved repository order, `OPENCODE_TEST_CHIP_UNREAD` the two unread
/// repositories (in manual order), `OPENCODE_TEST_CHIP_SESSION` the title to read in the second one, and
/// `OPENCODE_TEST_CHIP_RUN_PROJECT`/`OPENCODE_TEST_CHIP_RUN_SESSION` a read repository and the session ID the test
/// runs briefly with one Luna 6 / low prompt.
@MainActor final class SessionChipsTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testRunningThenUnreadThenManualOrderAndClearingAfterReading() throws {
    continueAfterFailure = false
    let manual = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_MANUAL"]).split(separator: ",").map(String.init)
    let unread = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_UNREAD"]).split(separator: ",").map(String.init)
    let title = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_SESSION"])
    let run = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_RUN_PROJECT"])
    let runSession = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_RUN_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = password
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 20))
    let read = manual.filter { !unread.contains($0) }

    // Unread repositories first, in the saved order; then the rest in the saved order; Chats (no saved
    // position) after every positioned chip.
    XCTAssertTrue(settled(app, order: ["Todas"] + unread + read + ["Chats"]))
    for name in manual {
      XCTAssertEqual(chip(name, app).label, unread.contains(name) ? name + ", com não lidas" : name)
    }
    shot("chips-unread")

    // A running repository rises right after "Todas", above the unread ones.
    try prompt(runSession, password: password)
    XCTAssertTrue(settled(app, order: ["Todas", run] + unread + read.filter { $0 != run } + ["Chats"], timeout: 60))
    shot("chips-running")

    // Once it finishes it is unread too, so it returns among the unread chips at its saved position.
    let finished = manual.filter { unread.contains($0) || $0 == run }
    XCTAssertTrue(
      settled(app, order: ["Todas"] + finished + read.filter { $0 != run } + ["Chats"], timeout: 180))
    shot("chips-finished")

    chip(unread[1], app).tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    XCTAssertTrue(app.staticTexts["conversation-header-title"].waitForExistence(timeout: 30))
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["conversation-header-title"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 10))

    // Reading clears the dot; the chip returns to its saved place among the read chips.
    let stillUnread = finished.filter { $0 != unread[1] }
    XCTAssertTrue(
      settled(app, order: ["Todas"] + stillUnread + manual.filter { !stillUnread.contains($0) } + ["Chats"]))
    XCTAssertEqual(chip(unread[1], app).label, unread[1])
    // The active filter stays visible after moving.
    let selected = chip(unread[1], app)
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in selected.frame.minX >= 0 && selected.frame.maxX <= app.frame.maxX + 1 },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "Selected chip off screen")
    shot("chips-after-reading")
    app.buttons["Todas"].firstMatch.tap()
  }

  /// A short real execution: one foreground shell sleep, so the chip stays running for a few seconds.
  private func prompt(_ session: String, password: String) throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + "/api/session/" + session + "/prompt")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "text":
        "Use somente a ferramenta shell, em primeiro plano, com command=\"sleep 20\". Não use outras ferramentas. Depois responda apenas: ok"
    ])
    let done = expectation(description: "prompt admitted")
    var status = 0
    URLSession.shared.dataTask(with: request) { _, response, _ in
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 30)
    XCTAssertTrue((200..<300).contains(status), "Prompt failed with HTTP \(status)")
  }
  private func chip(_ name: String, _ app: XCUIApplication) -> XCUIElement {
    switch name {
    case "Chats": app.buttons["filter-chats"]
    case "Todas": app.buttons["Todas"].firstMatch
    default: app.buttons["filter-project-" + name]
    }
  }
  /// Chip frames in the horizontal strip, compared left to right once the reorder animation settles.
  private func settled(_ app: XCUIApplication, order: [String], timeout: TimeInterval = 30) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let elements = order.map { self.chip($0, app) }
        guard elements.allSatisfy(\.exists) else { return false }
        let positions = elements.map(\.frame.minX)
        return zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
      }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
