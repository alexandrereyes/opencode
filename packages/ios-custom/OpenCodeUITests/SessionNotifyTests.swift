import XCTest

/// "Avisar ao terminar" in the Sessões rows, driven by `script/test-session-notify.py` on a freshly created simulator
/// and an owned sandbox: TARGET was muted by an older build, OTHER has the bell on (set through the server). The
/// runner's control server (`OPENCODE_NOTIFY_CONTROL`) opens a notification's deep link with `xcrun simctl openurl`.
@MainActor final class SessionNotifyTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "notify-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func control(_ path: String) async throws {
    let url = URL(string: try XCTUnwrap(environment["OPENCODE_NOTIFY_CONTROL"]) + path)!
    let (data, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
  }
  private func wait(_ element: XCUIElement, label: String, present: Bool) {
    let predicate = NSPredicate(format: present ? "label CONTAINS %@" : "NOT (label CONTAINS %@)", label)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 15), .completed,
      element.label)
  }

  /// Asks the runner to open a notification's deep link. `simctl openurl` asks before opening the app's scheme (a
  /// notification tap does not); the prompt sometimes swallows the first tap while it animates in, so the link is
  /// opened again once if nothing happened.
  private func openLink(_ path: String, showing header: XCUIElement, title: String) async throws -> Bool {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for _ in 0..<2 {
      try await control(path)
      let open = springboard.buttons["Abrir"]
      if open.waitForExistence(timeout: 5) {
        try await Task.sleep(for: .seconds(1))
        open.tap()
      }
      if shows(header, title) { return true }
    }
    return false
  }

  private func shows(_ element: XCUIElement, _ label: String) -> Bool {
    XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)],
      timeout: 10) == .completed
  }

  func testBellReplacesMuteInRowsSwipeAndMenu() async throws {
    let target = try XCTUnwrap(environment["OPENCODE_NOTIFY_TARGET"])
    let other = try XCTUnwrap(environment["OPENCODE_NOTIFY_OTHER"])
    let title = try XCTUnwrap(environment["OPENCODE_NOTIFY_TITLE"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    try app.requireSandbox()
    let row = app.buttons["session-row-" + target]
    let bell = app.buttons["session-row-" + other]
    app.revealSessionRow(row)
    // Muted by an older build: now an ordinary unread row (orange dot), no longer "silenciada", and no bell.
    XCTAssertTrue(row.label.contains(", não lida"), row.label)
    XCTAssertFalse(row.label.contains(", silenciada"), row.label)
    XCTAssertFalse(row.label.contains("avisa ao terminar"), row.label)
    // The bell turned on elsewhere (the Mestra or another device) shows on its row.
    XCTAssertTrue(bell.label.contains(", avisa ao terminar"), bell.label)
    shot("rows")

    row.swipeLeft()
    XCTAssertTrue(app.buttons["Avisar ao terminar"].waitForExistence(timeout: 5))
    for gone in ["Silenciar", "Reativar", "Não avisar"] { XCTAssertFalse(app.buttons[gone].exists, gone) }
    let order = ["Avisar ao terminar", "Arquivar", "Renomear", "Excluir"].map { app.buttons[$0].frame.minX }
    XCTAssertEqual(order, order.sorted())
    shot("swipe-off")
    row.swipeRight()
    XCTAssertTrue(app.buttons["Avisar ao terminar"].waitForNonExistence(timeout: 5))

    row.press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Avisar ao terminar"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Silenciar"].exists)
    shot("menu-off")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.62)).tap()
    XCTAssertTrue(app.buttons["Avisar ao terminar"].waitForNonExistence(timeout: 5))

    bell.swipeLeft()
    XCTAssertTrue(app.buttons["Não avisar"].waitForExistence(timeout: 5))
    shot("swipe-on")
    try await Task.sleep(for: .seconds(1))
    app.buttons["Não avisar"].tap()
    wait(bell, label: ", avisa ao terminar", present: false)
    shot("bell-off")

    // A notification tap follows the same link as a Live Activity: from another session it opens the finished one.
    bell.tap()
    let header = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(header.waitForExistence(timeout: 20))
    XCTAssertNotEqual(header.label, title)
    let opened = try await openLink("/open", showing: header, title: title)
    XCTAssertTrue(opened, header.label)
    shot("opened-from-link")
  }

  /// A question or permission alert opens its session at the pending request, even when he left it scrolled up.
  func testRequestAlertOpensAtThePendingRequest() async throws {
    let target = try XCTUnwrap(environment["OPENCODE_NOTIFY_REQUEST"])
    let title = try XCTUnwrap(environment["OPENCODE_NOTIFY_REQUEST_TITLE"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    try app.requireSandbox()
    let row = app.buttons["session-row-" + target]
    app.revealSessionRow(row)
    row.tap()
    let header = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(header.waitForExistence(timeout: 20))
    let allow = app.buttons["Permitir"]
    XCTAssertTrue(allow.waitForExistence(timeout: 30))
    // Leave it read from the top, far from the pending card.
    let transcript = app.collectionViews.firstMatch
    for _ in 0..<12 { transcript.swipeDown(velocity: .fast) }
    XCTAssertFalse(allow.exists && allow.isHittable, "O pedido deveria ter saído da tela")
    shot("request-scrolled-up")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 10))
    let reopened = try await openLink("/open-request", showing: header, title: title)
    XCTAssertTrue(reopened, header.label)
    XCTAssertTrue(allow.waitForExistence(timeout: 15))
    XCTAssertTrue(allow.isHittable, "O alerta deve abrir no pedido pendente")
    shot("opened-at-request")
  }
}
