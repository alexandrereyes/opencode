import XCTest

@MainActor final class ScrollComparisonTests: XCTestCase {
  func testGrowingTailPerformance() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177",
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "tail",
      "-OpenCodeFixtureFollow", "-OpenCodeFixtureMeasureGrowth", "-OpenCodeTheme", "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    options.invocationOptions = [.manuallyStart, .manuallyStop]
    measure(metrics: [XCTCPUMetric(application: app),
      XCTOSSignpostMetric(subsystem: "br.com.alexandrem.opencode", category: "PointsOfInterest", name: "FixtureGrowth")], options: options) {
      app.launch()
      let list = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(list.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: list)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      let driver = app.buttons["growth-measurement"]
      startMeasuring()
      driver.tap()
      let done = expectation(for: NSPredicate(format: "value BEGINSWITH '{'"), evaluatedWith: driver)
      XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
      stopMeasuring()
      let attachment = XCTAttachment(string: driver.value as? String ?? "missing")
      attachment.name = "growing-tail-frames"
      attachment.lifetime = .keepAlways
      add(attachment)
      app.terminate()
    }
  }
}
