import XCTest

/// Captures the "Agentes" Live Activity started by the DEBUG fixture: compact (or minimal, with two fixtures) and
/// expanded Dynamic Island, then the Lock Screen presentation through Notification Center. Needs no server.
/// `TEST_RUNNER_OPENCODE_AGENTS_FIXTURE=state-mixed TEST_RUNNER_OPENCODE_CAPTURE_DIR=/abs/dir xcodebuild test …`.
final class AgentsActivityCaptureTests: XCTestCase {
  func testCaptureAgentsActivity() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["OPENCODE_CAPTURE_DIR"], let fixture = environment["OPENCODE_AGENTS_FIXTURE"]
    else { throw XCTSkip("Defina OPENCODE_CAPTURE_DIR e OPENCODE_AGENTS_FIXTURE.") }
    let name = fixture.replacingOccurrences(of: ",", with: "+")
    func save(_ variant: String) throws {
      let url = URL(fileURLWithPath: directory).appending(path: "ios-\(name)-\(variant).png")
      try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeAgentsActivityFixture", fixture, "-OpenCodeTheme", "openchamber-dark"]
    app.launch()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    sleep(4)
    XCUIDevice.shared.press(.home)
    sleep(3)
    try save(fixture.contains(",") ? "minimal" : "compact")
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.028)).press(forDuration: 1.5)
    sleep(2)
    try save("expanded")
    springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
    sleep(2)
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
  }
}
