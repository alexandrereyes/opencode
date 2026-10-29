import XCTest

/// A repository chip without sessions shows only "Arquivadas N", and nothing moves while the server keeps the list
/// reloading. Needs `OPENCODE_TEST_EMPTY_PROJECT` (a selected repository without root sessions) and
/// `OPENCODE_TEST_EVENTS_SESSION` (a session of another repository that runs one Luna 6 / low shell sleep, so every
/// step of it reloads the list).
@MainActor final class SessionsEmptyFilterTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testRepositoryWithoutSessionsShowsOnlyArchivedAndStaysStillWhileReloading() throws {
    continueAfterFailure = false
    let project = try XCTUnwrap(environment["OPENCODE_TEST_EMPTY_PROJECT"])
    let session = try XCTUnwrap(environment["OPENCODE_TEST_EVENTS_SESSION"])
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = password
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))
    try app.requireSandbox()

    let chip = app.buttons["filter-project-" + project]
    let strip = app.scrollViews.firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 20))
    for _ in 0..<6 where !chip.isHittable { strip.swipeLeft(velocity: .slow) }
    chip.tap()
    // Project chips carry no selected trait; "Todas" losing it confirms the repository filter.
    let deselected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == false"),
      object: app.buttons["filter-all"])
    XCTAssertEqual(XCTWaiter.wait(for: [deselected], timeout: 10), .completed)
    let archived = app.buttons["sessions-archived"]
    XCTAssertTrue(archived.waitForExistence(timeout: 10))
    let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'"))
    XCTAssertEqual(rows.count, 0)
    shot("empty-repository")

    // A real execution elsewhere: its steps reload the list repeatedly while this filter is shown.
    try prompt(session, password: password)
    let resting = archived.frame
    let deadline = Date().addingTimeInterval(12)
    var samples = 0
    while Date() < deadline {
      XCTAssertFalse(app.staticTexts["Nenhuma sessão"].exists, "Estado vazio na lista")
      XCTAssertFalse(app.activityIndicators.firstMatch.exists, "Progresso numa recarga")
      XCTAssertTrue(archived.exists)
      XCTAssertEqual(archived.frame.minY, resting.minY, accuracy: 0.5, "Arquivadas mudou de lugar")
      XCTAssertEqual(rows.count, 0)
      samples += 1
      Thread.sleep(forTimeInterval: 0.25)
    }
    XCTAssertGreaterThan(samples, 10)
    shot("empty-repository-reloading")
  }

  private func prompt(_ session: String, password: String) throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + "/api/session/" + session + "/prompt")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "text":
        "Use somente a ferramenta shell, em primeiro plano, com command=\"sleep 8\". Não use outras ferramentas. Depois responda apenas: ok"
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
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
