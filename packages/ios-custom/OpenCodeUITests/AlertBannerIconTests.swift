import XCTest

/// The in-app alert banner uses the project's own icon (`project.icon.override`), like the Sessões rows.
/// `OPENCODE_TEST_BANNER_SESSION` is a root session of a project whose icon clearly shows `OPENCODE_TEST_BANNER_COLOR`
/// (RRGGBB); the test sends it one Luna 6 / low prompt and waits for its completion banner.
@MainActor final class AlertBannerIconTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testCompletionBannerShowsTheProjectIcon() throws {
    continueAfterFailure = false
    let session = try XCTUnwrap(environment["OPENCODE_TEST_BANNER_SESSION"])
    let color = try XCTUnwrap(environment["OPENCODE_TEST_BANNER_COLOR"])
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = password
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))
    try app.requireSandbox()

    try prompt(session, password: password)
    let banner = app.buttons["session-alert-open"]
    XCTAssertTrue(banner.waitForExistence(timeout: 120))
    // The banner lasts a few seconds: capture it at once, then check its avatar's pixels.
    let shot = XCUIScreen.main.screenshot()
    let lit = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in banner.exists && banner.pixels(near: color, leading: 64) > 40 }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [lit], timeout: 5), .completed, "Ícone do projeto na faixa")
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = "banner-project-icon-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func prompt(_ session: String, password: String) throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + "/api/session/" + session + "/prompt")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["text": "Responda apenas: pronto"])
    let done = expectation(description: "prompt admitted")
    var status = 0
    URLSession.shared.dataTask(with: request) { _, response, _ in
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 30)
    XCTAssertTrue((200..<300).contains(status), "Prompt failed with HTTP \(status)")
  }
}
