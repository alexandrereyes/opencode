import XCTest

/// Você ▸ Segurança ▸ Exigir Face ID on the offline catalog, with `AppLockFixture` answering each Face ID prompt.
/// Server-free; the real LocalAuthentication prompt is covered by `AppLockRealFaceIDTests`.
@MainActor final class AppLockTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  private func launch(on: Bool, answers: String, delay: String = "0.3", extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4183", "-OpenCodeTheme", "openchamber-dark",
      "-OpenCodeScrollFixture", "catalog", "-OpenCodeFixturePosition", "top", "-OpenCodeFixtureServers",
      "-OpenCodeFaceIDLock", on ? "YES" : "NO", "-OpenCodeAppLockFixture", answers,
      "-OpenCodeAppLockFixtureDelay", delay] + extra
    app.launch()
    return app
  }

  private func lockScreen(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["app-lock"].firstMatch }
  private func row(_ app: XCUIApplication) -> XCUIElement { app.buttons["session-row-ses_scroll_0000"] }
  private func prompts(_ app: XCUIApplication) -> String { app.staticTexts["app-lock-prompts"].label }

  /// The switch at the row's trailing edge; the label does not toggle it.
  private func flip(_ toggle: XCUIElement) { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }

  private func waitValue(_ element: XCUIElement, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
    let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
    XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 5), .completed, file: file, line: line)
  }

  private func leaveAndReturn(_ app: XCUIApplication) {
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }

  func testTurningOnAndOffNeedsFaceID() {
    let app = launch(on: false, answers: "cancel,success,notRecognized,success")
    defer { app.terminate() }
    XCTAssertTrue(row(app).waitForExistence(timeout: 20))
    XCTAssertFalse(lockScreen(app).exists)
    app.openYou()
    let toggle = app.switches["settings-face-id"]
    for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
    XCTAssertEqual(toggle.value as? String, "0")
    XCTAssertTrue(app.staticTexts["Exigir Face ID ao abrir e sempre que voltar ao app."].exists)

    // A cancelled Face ID leaves it off and says why.
    flip(toggle)
    XCTAssertTrue(app.staticTexts["settings-face-id-error"].waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.value as? String, "0")
    flip(toggle)
    waitValue(toggle, "1")
    // Turning it on does not lock the screen he is on.
    XCTAssertFalse(lockScreen(app).exists)

    // Off needs Face ID too: a wrong face keeps it on.
    flip(toggle)
    XCTAssertTrue(app.staticTexts["settings-face-id-error"].waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.value as? String, "1")
    flip(toggle)
    waitValue(toggle, "0")
    leaveAndReturn(app)
    XCTAssertFalse(lockScreen(app).waitForExistence(timeout: 2))
  }

  func testFaceIDMissingKeepsItOff() {
    let app = launch(on: false, answers: "success", extra: ["-OpenCodeAppLockFixtureUnavailable", "notEnrolled"])
    defer { app.terminate() }
    app.openYou()
    let toggle = app.switches["settings-face-id"]
    for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
    flip(toggle)
    let failure = app.staticTexts["settings-face-id-error"]
    XCTAssertTrue(failure.waitForExistence(timeout: 5))
    XCTAssertTrue(failure.label.contains("Cadastre o Face ID"))
    XCTAssertEqual(toggle.value as? String, "0")
  }

  /// Cold start covered; a cancelled prompt stays locked without asking again; Tentar novamente opens it.
  func testColdStartIsLockedAndACancelDoesNotLoop() {
    let app = launch(on: true, answers: "cancel,success")
    defer { app.terminate() }
    XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 20))
    let message = app.staticTexts["app-lock-message"]
    XCTAssertTrue(message.wait(for: \.label, toEqual: "O Face ID foi cancelado.", timeout: 10))
    // Hidden content is neither visible to accessibility nor reachable.
    XCTAssertFalse(row(app).exists)
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    XCTAssertEqual(prompts(app), "1")
    app.buttons["app-lock-retry"].tap()
    XCTAssertTrue(lockScreen(app).waitForNonExistence(timeout: 10))
    XCTAssertTrue(row(app).waitForExistence(timeout: 10))
  }

  /// Leaving with Você open over a conversation whose composer has the keyboard: all of it is covered, the
  /// keyboard is gone, and after Face ID the sheet is still there.
  func testLeavingCoversSheetsAndTheComposer() {
    // Slow enough to see the cover before Face ID answers.
    let app = launch(on: true, answers: "success", delay: "2.5")
    defer { app.terminate() }
    XCTAssertTrue(row(app).waitForExistence(timeout: 20))
    row(app).tap()
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText("Texto que não pode aparecer")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

    leaveAndReturn(app)
    XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 5))
    XCTAssertFalse(editor.exists)
    XCTAssertFalse(app.keyboards.firstMatch.exists)
    XCTAssertTrue(lockScreen(app).waitForNonExistence(timeout: 10))
    XCTAssertTrue(editor.waitForExistence(timeout: 5))

    app.openYou()
    leaveAndReturn(app)
    XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars["Você"].exists)
    XCTAssertTrue(app.staticTexts["app-lock-prompts"].wait(for: \.label, toEqual: "3", timeout: 3))
    XCTAssertTrue(lockScreen(app).waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.navigationBars["Você"].waitForExistence(timeout: 5))
  }

  /// Turning the lock off covers Você while its own prompt is up; a cancel keeps it on and uncovers without asking.
  func testTurningOffIsCoveredWhileItsPromptIsUp() {
    // Long enough for the queries below while the turn-off prompt is still up.
    let app = launch(on: true, answers: "success,cancel", delay: "6")
    defer { app.terminate() }
    XCTAssertTrue(row(app).waitForExistence(timeout: 20))
    app.openYou()
    let toggle = app.switches["settings-face-id"]
    for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
    waitValue(toggle, "1")
    flip(toggle)
    XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["app-lock-prompts"].wait(for: \.label, toEqual: "2", timeout: 2))
    XCTAssertFalse(app.navigationBars["Você"].exists)
    XCTAssertFalse(app.buttons["app-lock-retry"].exists)
    XCTAssertTrue(lockScreen(app).waitForNonExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["settings-face-id-error"].waitForExistence(timeout: 5))
    waitValue(toggle, "1")
    // No prompt follows the cancel.
    XCTAssertFalse(lockScreen(app).waitForExistence(timeout: 4))
  }

  /// Inactive only, without the background: Control Center over the app covers it, and coming back asks Face ID.
  func testControlCenterCoversAndAsksAgain() {
    let app = launch(on: true, answers: "success", delay: "2.5")
    defer { app.terminate() }
    XCTAssertTrue(row(app).waitForExistence(timeout: 20))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.001)).press(forDuration: 0.1,
      thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.6)))
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    XCTAssertEqual(app.state, .runningForeground, "Control Center sent the app to the background")
    XCTAssertTrue(lockScreen(app).exists)
    XCTAssertFalse(row(app).exists)
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).press(forDuration: 0.1,
      thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    XCTAssertTrue(app.staticTexts["app-lock-prompts"].wait(for: \.label, toEqual: "2", timeout: 5))
    XCTAssertTrue(lockScreen(app).waitForNonExistence(timeout: 10))
    XCTAssertTrue(row(app).exists)
  }

  /// Going to the background while Face ID is checking: that answer, even a success, never opens it.
  func testBackgroundDuringThePromptRefusesItsLateSuccess() {
    let app = launch(on: true, answers: "success", delay: "4")
    defer { app.terminate() }
    XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["app-lock-message"].wait(for: \.label, toEqual: "Confirmando o Face ID…", timeout: 5))
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    // Past the first prompt's answer, while away.
    RunLoop.current.run(until: Date().addingTimeInterval(5))
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(lockScreen(app).exists)
    XCTAssertFalse(row(app).exists)
    XCTAssertTrue(app.staticTexts["app-lock-prompts"].wait(for: \.label, toEqual: "2", timeout: 3))
    XCTAssertTrue(lockScreen(app).waitForNonExistence(timeout: 10))
    XCTAssertTrue(row(app).exists)
  }
}

/// The real LocalAuthentication prompt on a simulator with Face ID enrolled; `script/test-app-lock.py` enrolls a face
/// and keeps matching it while this runs (`TEST_RUNNER_OPENCODE_REAL_FACEID=1`). The system prompt takes the scene's
/// focus and gives it back: after Face ID opens the app, that cycle must neither lock it again nor ask again.
@MainActor final class AppLockRealFaceIDTests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENCODE_REAL_FACEID"] == "1", "Needs test-app-lock.py")
  }

  func testFaceIDOpensOnceWithoutLooping() {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4183", "-OpenCodeTheme", "openchamber-dark",
      "-OpenCodeScrollFixture", "catalog", "-OpenCodeFixturePosition", "top", "-OpenCodeFixtureServers",
      "-OpenCodeFaceIDLock", "YES"]
    app.launch()
    defer { app.terminate() }
    let lock = app.descendants(matching: .any)["app-lock"].firstMatch
    let row = app.buttons["session-row-ses_scroll_0000"]
    XCTAssertTrue(lock.waitForExistence(timeout: 20))
    XCTAssertFalse(row.exists)
    // iOS asks once whether MyAgents may use Face ID.
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for label in ["OK", "Permitir", "Allow"] where springboard.buttons[label].waitForExistence(timeout: label == "OK" ? 8 : 1) {
      springboard.buttons[label].tap()
      break
    }
    XCTAssertTrue(lock.waitForNonExistence(timeout: 20), "Face ID did not open the app")
    // The prompt's own inactive/active cycle: nothing locks or asks again while matches keep coming.
    XCTAssertFalse(lock.waitForExistence(timeout: 6))
    XCTAssertTrue(row.exists)

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    // Locked again on return (AppLockTests checks the cover itself); the matching face opens it once more.
    XCTAssertTrue(lock.waitForNonExistence(timeout: 20))
    XCTAssertFalse(lock.waitForExistence(timeout: 6))
    XCTAssertTrue(row.exists)
  }
}
