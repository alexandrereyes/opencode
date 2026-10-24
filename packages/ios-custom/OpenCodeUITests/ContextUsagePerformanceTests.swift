import XCTest

@MainActor final class ContextUsagePerformanceTests: XCTestCase {
  func testMeasuredConversationScrolling() {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
      "-OpenCodeFixturePosition", "middle", "-OpenCodeContextUsageFixture", "-OpenCodeTheme", "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    let list = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(list.waitForExistence(timeout: 20))
    let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: list)
    wait(for: [ready], timeout: 20)
    let options = XCTMeasureOptions()
    options.iterationCount = 5
    measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)], options: options) {
      list.swipeUp(velocity: .fast)
      list.swipeUp(velocity: .fast)
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
    }
    app.terminate()
  }
}
