import XCTest

/// Reading chat answers aloud against the sandbox's real `custom.speech`. Run through `script/test-file-viewer.py`.
@MainActor final class ChatReadAloudTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  override func record(_ issue: XCTIssue) {
    var issue = issue
    issue.add(XCTAttachment(screenshot: MainActor.assumeIsolated { XCUIScreen.main.screenshot() }))
    super.record(issue)
  }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "chat-read-aloud-" + name + "-" + (theme.hasSuffix("light") ? "claro" : "escuro")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func expect(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval, _ message: String) {
    let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed, message)
  }
  /// Elapsed seconds in the pill (`m:ss de m:ss`).
  private func elapsed(_ app: XCUIApplication) -> Int {
    let value = app.buttons["read-aloud-expand"].value as? String ?? ""
    return (value.components(separatedBy: " de ").first ?? "").split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
  }
  private func launch() throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_CHAT_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    return app
  }
  private func answer(_ app: XCUIApplication, _ key: String) throws -> XCUIElement {
    let button = app.buttons["read-aloud-message-" + (try XCTUnwrap(environment[key]))]
    XCTAssertTrue(button.waitForExistence(timeout: 20), key)
    for _ in 0..<6 where !button.isHittable { app.collectionViews["conversation-transcript"].swipeDown(velocity: .slow) }
    return button
  }

  func testAnswerPlaysSwitchesAndResumesWhereItStopped() throws {
    var app = try launch()
    let pill = app.otherElements["read-aloud-pill"]
    let play = app.buttons["read-aloud-play"]
    let second = try answer(app, "OPENCODE_CHAT_SECOND")
    XCTAssertFalse(pill.exists, "no player before an answer is chosen")
    // Only finished answers with text have the button: the tool step inside the second turn does not.
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'read-aloud-message-'")).count, 2)
    screenshot("rodape")
    second.tap()
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    expect(play, "label == %@", "Pausar leitura", timeout: 45, "the last answer plays")
    let deadline = Date.now.addingTimeInterval(20)
    while elapsed(app) < 4, Date.now < deadline { Thread.sleep(forTimeInterval: 0.2) }
    screenshot("tocando")
    play.tap()
    expect(play, "label == %@", "Ouvir documento", timeout: 5, "paused")
    let stopped = elapsed(app)
    XCTAssertGreaterThanOrEqual(stopped, 4)

    // Another answer replaces it and starts from its top.
    try answer(app, "OPENCODE_CHAT_FIRST").tap()
    expect(play, "label == %@", "Pausar leitura", timeout: 45, "the first answer plays")
    XCTAssertLessThan(elapsed(app), stopped)
    app.buttons["read-aloud-expand"].tap()
    XCTAssertTrue(app.buttons["read-aloud-reveal"].waitForExistence(timeout: 5))
    screenshot("expandida")
    app.buttons["read-aloud-collapse"].tap()

    // Reopening the conversation: the last answer opens paused where it stopped, without playing by itself.
    app.terminate()
    app = try launch()
    try answer(app, "OPENCODE_CHAT_SECOND").tap()
    XCTAssertTrue(app.otherElements["read-aloud-pill"].waitForExistence(timeout: 10))
    expect(app.buttons["read-aloud-expand"], "NOT (value BEGINSWITH %@)", "0:00 ", timeout: 10, "the saved place")
    XCTAssertEqual(Double(elapsed(app)), Double(stopped), accuracy: 1.5)
    XCTAssertEqual(app.buttons["read-aloud-play"].label, "Ouvir documento")
    screenshot("retomada-pausada")
    app.buttons["read-aloud-play"].tap()
    expect(app.buttons["read-aloud-play"], "label == %@", "Pausar leitura", timeout: 45, "resumes")
    XCTAssertGreaterThanOrEqual(elapsed(app), stopped - 1)
    // Start over clears the saved place.
    app.buttons["read-aloud-expand"].tap()
    app.buttons["read-aloud-restart"].tap()
    app.terminate()
  }
}
