import XCTest

/// Viewer shell (layout B) against a real hub resource: `OPENCODE_TEST_RESOURCE` is a running simulator registered
/// in the sandbox's hub by `script/test-resources.py`, which also checks the agent lock on the server side.
@MainActor final class ResourceViewerTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "resources-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private struct Resource: Decodable {
    struct Output: Decodable { let state: String }
    let output: Output
  }
  private func state(_ id: String) async throws -> String {
    var request = URLRequest(url: URL(string: TestSandbox.url + "/api/rpc/custom.resources/get")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["input": ["id": id]])
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(Resource.self, from: data).output.state
  }

  func testWatchTakeControlShowControlsAndGiveBack() async throws {
    let id = try XCTUnwrap(environment["OPENCODE_TEST_RESOURCE"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenResource", id]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }

    // Watching: the frame arrives, the status reads live with a round trip, the agent holds the resource.
    XCTAssertTrue(app.images["resource-frame"].waitForExistence(timeout: 30))
    let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' ms'")).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 15), "status shows the stream round trip")
    XCTAssertTrue(app.staticTexts["opushigh no controle"].exists)
    let take = app.buttons["resource-take"]
    XCTAssertTrue(take.exists)
    screenshot("watching")

    // Only watching, a tap on the screen toggles the controls.
    let screen = app.otherElements["resource-touch"]
    screen.tap()
    XCTAssertTrue(take.waitForNonExistence(timeout: 5))
    screenshot("watching-hidden")
    screen.tap()
    XCTAssertTrue(take.waitForExistence(timeout: 5))

    // In control the controls hide, the pill and the edge handle remain, and touches go to the resource.
    take.tap()
    let pill = app.buttons["resource-control-pill"]
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    let handle = app.buttons["resource-handle"]
    XCTAssertTrue(handle.waitForExistence(timeout: 5))
    XCTAssertFalse(take.exists)
    let held = try await state(id)
    XCTAssertEqual(held, "user")
    screenshot("control")
    screen.tap()
    XCTAssertFalse(app.buttons["resource-close"].exists, "a touch in control never toggles the controls")
    handle.tap()
    let giveBack = app.buttons["resource-give-back"]
    XCTAssertTrue(giveBack.waitForExistence(timeout: 5))
    screenshot("control-controls")

    giveBack.tap()
    XCTAssertTrue(take.waitForExistence(timeout: 10))
    XCTAssertFalse(pill.exists)
    let returned = try await state(id)
    XCTAssertNotEqual(returned, "user")
    app.buttons["resource-close"].tap()
    XCTAssertTrue(take.waitForNonExistence(timeout: 5))
  }
}
