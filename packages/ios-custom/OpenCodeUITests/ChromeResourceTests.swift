import XCTest

/// Chrome viewer against an isolated sandbox and a real headless Chrome showing the login fixture
/// (`packages/plugin-app-custom/script/chrome-login-fixture.ts`). Run it with `script/test-chrome-resource.py`, which
/// opens the browser through the sandbox's shell, registers it and passes:
/// `OPENCODE_TEST_RESOURCE` (resource ID), `OPENCODE_TEST_FIXTURE_URL` (fixture origin) and
/// `OPENCODE_TEST_FIELDS` (normalized frame `y` of the e-mail and password fields, comma-separated).
@MainActor final class ChromeResourceTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testWatchTakeControlTypeLoginNavigateAndGiveBack() async throws {
    continueAfterFailure = false
    let resource = try XCTUnwrap(environment["OPENCODE_TEST_RESOURCE"])
    let fixture = try XCTUnwrap(environment["OPENCODE_TEST_FIXTURE_URL"])
    let fields = try XCTUnwrap(environment["OPENCODE_TEST_FIELDS"]).split(separator: ",").compactMap { Double($0) }
    XCTAssertEqual(fields.count, 2)
    let host = fixture.replacingOccurrences(of: "http://", with: "")
    _ = try await get(fixture + "/reset")

    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenResource", resource]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()

    // Watching: the live frame and the address bar; navigation is disabled until control is taken.
    let frame = app.images["resource-frame"]
    XCTAssertTrue(frame.waitForExistence(timeout: 30))
    let address = app.textFields["chrome-address"]
    XCTAssertTrue(address.waitForExistence(timeout: 10))
    try await expect { (address.value as? String)?.hasSuffix("/login") == true }
    XCTAssertFalse(app.buttons["chrome-reload"].isEnabled)
    shot("view")

    app.buttons["resource-take"].tap()
    XCTAssertTrue(app.buttons["resource-give-back"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["resource-control-pill"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["chrome-reload"].isEnabled)
    let controlled = try await state(resource)
    XCTAssertEqual(controlled, "user")
    shot("control")

    // The e-mail field opens the keyboard by itself; typing goes to the page.
    frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fields[0])).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["chrome-give-back-inline"].waitForExistence(timeout: 5))
    app.typeText("alexandre@abacato.app")

    // The password field switches the hidden field to secure entry (`.password` content type for AutoFill).
    frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fields[1])).tap()
    XCTAssertTrue(app.secureTextFields["resource-keyboard"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
    try await Task.sleep(for: .milliseconds(800))
    shot("password")
    app.typeText("s3cr3t!x")
    shot("password-typed")
    app.typeText("\n")
    try await expect {
      let last = try await self.json(fixture + "/last")
      return last["email"] as? String == "alexandre@abacato.app" && last["passwordLength"] as? Int == 8
    }

    // Back on the login page (the form posts to /login), scroll it with a finger.
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
    address.tap()
    address.typeText(host + "/login\n")
    try await expect { try await self.title(resource) == "Entrar · Abacato" }
    frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
      .press(forDuration: 0.05, thenDragTo: frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    try await expect { (try await self.json(fixture + "/last"))["maxScroll"] as? Int ?? 0 > 0 }
    shot("scrolled")

    // Address bar navigation, then back.
    address.tap()
    address.typeText(host + "/ajuda\n")
    try await expect { (address.value as? String)?.hasSuffix("/ajuda") == true }
    XCTAssertTrue(app.buttons["chrome-back"].waitForEnabled(timeout: 10))
    app.buttons["chrome-back"].tap()
    try await expect { (address.value as? String)?.hasSuffix("/login") == true }
    XCTAssertTrue(app.buttons["chrome-forward"].waitForEnabled(timeout: 15))
    shot("back")

    app.buttons["resource-give-back"].tap()
    XCTAssertTrue(app.buttons["resource-take"].waitForExistence(timeout: 10))
    try await expect { try await self.state(resource) != "user" }
  }

  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "chrome-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Polls `condition` (UI or HTTP state) until it holds, failing the test after `timeout` seconds.
  private func expect(timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if (try? await condition()) == true { return }
      try await Task.sleep(for: .milliseconds(200))
    }
    XCTFail("Condition not met within \(timeout) s", file: file, line: line)
    throw CancellationError()
  }

  private func get(_ url: String) async throws -> Data {
    try await URLSession.shared.data(from: XCTUnwrap(URL(string: url))).0
  }

  private func json(_ url: String) async throws -> [String: Any] {
    let data = try await get(url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func resourceInfo(_ id: String) async throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + "/api/rpc/custom.resources/get")))
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["input": ["id": id]])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let data = try await URLSession.shared.data(for: request).0
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(body["output"] as? [String: Any])
  }

  private func state(_ id: String) async throws -> String? { try await resourceInfo(id)["state"] as? String }

  private func title(_ id: String) async throws -> String? {
    (try await resourceInfo(id)["meta"] as? [String: Any])?["title"] as? String
  }
}

private extension XCUIElement {
  func waitForEnabled(timeout: Double) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if exists && isEnabled { return true }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }
    return false
  }
}
