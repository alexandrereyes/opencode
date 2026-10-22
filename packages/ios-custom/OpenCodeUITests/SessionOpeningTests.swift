import XCTest

@MainActor final class SessionOpeningTests: XCTestCase {
  func testOpeningTimings() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    for delay in [0, 400] {
      for old in [false, true] where delay > 0 || !old {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", "openchamber-dark",
          "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_HISTORY"])]
        app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
        app.launchEnvironment["OPENCODE_OPENING_TRACE"] = "1"
        app.launchEnvironment["OPENCODE_OPENING_SESSION"] = try XCTUnwrap(environment["OPENCODE_TEST_HISTORY"])
        app.launchEnvironment["OPENCODE_OPENING_DELAY_MS"] = String(delay)
        app.launchEnvironment["OPENCODE_OPENING_OLD_SERVER"] = old ? "1" : "0"
        app.launch()
        let metrics = app.otherElements["opening-metrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 30))
        let complete = expectation(for: NSPredicate(format: "value CONTAINS 'frame'"), evaluatedWith: metrics)
        wait(for: [complete], timeout: 30)
        print("OPENING_RESULT delay=\(delay) old=\(old) metrics=\(metrics.value ?? "missing")")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "opening-\(delay)-\(old)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Repeat with real navigation taps, excluding app launch and XCTest synthesis overhead.
        for repeatIndex in 0..<1 {
          app.buttons["Voltar"].tap()
          let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Conversa C — histórico e compositor'" )).firstMatch
          app.revealSessionRow(row)
          row.tap()
          let done = expectation(for: NSPredicate(format: "value CONTAINS 'frame'"), evaluatedWith: metrics)
          wait(for: [done], timeout: 30)
          print("OPENING_RESULT delay=\(delay) old=\(old) repeat=\(repeatIndex) metrics=\(metrics.value ?? "missing")")
        }
        app.terminate()
      }
    }
  }
}
