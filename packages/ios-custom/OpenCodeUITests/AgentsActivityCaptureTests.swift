import XCTest

/// Captures the "Agentes" Live Activity started by the DEBUG fixture: compact (or minimal, with two fixtures) and
/// expanded Dynamic Island, then the Lock Screen presentation through Notification Center. Needs no server.
/// `TEST_RUNNER_OPENCODE_AGENTS_FIXTURE="state-mixed state-working" TEST_RUNNER_OPENCODE_CAPTURE_DIR=/abs/dir
/// [TEST_RUNNER_OPENCODE_CAPTURE_PREFIX=ios-v2-max] [TEST_RUNNER_OPENCODE_CAPTURE_LOCK_ONLY=1] xcodebuild test-without-building …` (space-separated fixtures,
/// each one a comma-separated list of activities, all captured after a single install).
@MainActor final class AgentsActivityCaptureTests: XCTestCase {
  func testCaptureAgentsActivity() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["OPENCODE_CAPTURE_DIR"], let fixtures = environment["OPENCODE_AGENTS_FIXTURE"]
    else { throw XCTSkip("Defina OPENCODE_CAPTURE_DIR e OPENCODE_AGENTS_FIXTURE.") }
    let prefix = environment["OPENCODE_CAPTURE_PREFIX"] ?? "ios"
    let lockOnly = environment["OPENCODE_CAPTURE_LOCK_ONLY"] == "1"
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for fixture in fixtures.split(separator: " ").map(String.init) {
      let name = fixture.replacingOccurrences(of: ",", with: "+")
      func save(_ variant: String) throws {
        let url = URL(fileURLWithPath: directory).appending(path: "\(prefix)-\(name)-\(variant).png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
      }
      try launch(fixture)
      sleep(3)
      XCUIDevice.shared.press(.home)
      sleep(3)
      if !lockOnly {
        try save(fixture.contains(",") ? "minimal" : "compact")
        // A one-second touch and hold opens the expanded presentation; longer holds were sometimes ignored.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).press(forDuration: 1)
        sleep(2)
        try save("expanded")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        sleep(2)
      }
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.001)).press(forDuration: 0.1,
        thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
      // The Lock Screen draws the activity a few seconds after Notification Center opens.
      sleep(6)
      // First run: the Lock Screen card asks whether OpenCode may keep showing Live Activities.
      for label in ["Permitir", "Permitir Sempre"] where springboard.buttons[label].exists {
        springboard.buttons[label].tap()
        sleep(2)
      }
      try save("lock")
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).press(forDuration: 0.1,
        thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
      sleep(1)
    }
  }

  /// After an install SpringBoard may launch the app in the background without arguments (the normal root, against
  /// the default server), and `launch()` can attach to that process. Relaunch until the fixture screen shows.
  private func launch(_ fixture: String) throws {
    let app = XCUIApplication()
    // Also an unreachable server, should a launch ever lose the fixture argument.
    app.launchArguments = ["-OpenCodeAgentsActivityFixture", fixture, "-OpenCodeTheme", "openchamber-dark",
      "-OpenCodeServerURL", "http://127.0.0.1:9"]
    for _ in 0..<4 {
      app.terminate()
      sleep(1)
      app.launch()
      if app.staticTexts["Live Activity de exemplo"].waitForExistence(timeout: 8) { return }
    }
    XCTFail("The app did not start in fixture mode for \(fixture)")
  }
}
