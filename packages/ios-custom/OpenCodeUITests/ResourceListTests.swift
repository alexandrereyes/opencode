import XCTest

/// "Agentes e tarefas" with resources (layout 1B), from `script/test-resources.py --discovery [--android …]`: the
/// session itself used a simulator (`OPENCODE_TEST_RESOURCE`) and, optionally, an Android emulator
/// (`OPENCODE_TEST_ANDROID_RESOURCE`); a subagent opened a headless Chrome (`OPENCODE_TEST_CHILD_RESOURCE`). An
/// assistant message links each of them with `opencode-resource:`.
@MainActor final class ResourceListTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "resources-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testResourcesAppearPerAgentAndOpenFromListAndLink() throws {
    let resource = try XCTUnwrap(environment["OPENCODE_TEST_RESOURCE"])
    let child = try XCTUnwrap(environment["OPENCODE_TEST_CHILD_RESOURCE"])
    let android = environment["OPENCODE_TEST_ANDROID_RESOURCE"]
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))

    // The header pill counts the family's running resources beside its agents.
    let agents = app.buttons["conversation-agents"]
    XCTAssertTrue(agents.waitForExistence(timeout: 20))
    let counted = NSPredicate(format: "label CONTAINS %@", "\(android == nil ? 2 : 3) recursos ativos")
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: counted, evaluatedWith: agents)], timeout: 20), .completed)
    screenshot("conversation")

    // Each link in the response opens its viewer.
    let transcript = app.collectionViews["conversation-transcript"]
    let links = ["simulador de teste", "navegador de teste"] + (android == nil ? [] : ["emulador de teste"])
    for (index, name) in links.enumerated() {
      let link = app.links[name]
      for _ in 0..<8 where !link.isHittable { transcript.swipeDown() }
      XCTAssertTrue(link.waitForExistence(timeout: 10), name)
      if index == 0 { screenshot("link") }
      link.tap()
      opened(app, "link-\(index)")
    }

    // Esta sessão lists what the session used; the subagent row carries its own browser.
    agents.tap()
    XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    let own = [resource] + (android.map { [$0] } ?? [])
    let nested = app.buttons["resource-row-" + child]
    XCTAssertTrue(nested.waitForExistence(timeout: 15))
    for id in own {
      let row = app.buttons["resource-row-" + id]
      XCTAssertTrue(row.waitForExistence(timeout: 15), id)
      XCTAssertLessThan(row.frame.minY, nested.frame.minY, "own resources come before the subagents")
    }
    // Thumbnails arrive by snapshot; give the first ones time to load.
    sleep(4)
    screenshot("list")

    for (index, id) in (own + [child]).enumerated() {
      app.buttons["resource-row-" + id].tap()
      opened(app, "row-\(index)")
      XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 10))
    }
  }

  /// The viewer shows a frame; then it closes.
  private func opened(_ app: XCUIApplication, _ name: String) {
    XCTAssertTrue(app.images["resource-frame"].waitForExistence(timeout: 30), name)
    // Let the full-screen presentation settle: a dismissal requested during its transition is dropped.
    sleep(2)
    screenshot(name)
    let close = app.buttons["resource-close"]
    XCTAssertTrue(close.waitForExistence(timeout: 10), name)
    close.tap()
    XCTAssertTrue(app.images["resource-frame"].waitForNonExistence(timeout: 10), name)
  }
}
