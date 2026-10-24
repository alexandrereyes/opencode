import XCTest

/// Needs a sandbox Session in a listed project or in Chats (`OPENCODE_TEST_ORIGIN_SESSION`); set
/// `OPENCODE_TEST_ORIGIN_PROJECT` to the project name, or to `Chats` for a chat. Sends one short prompt.
@MainActor final class MenuNewSessionTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testMenuNewSessionInheritsProjectCheckoutAndModel() throws {
    continueAfterFailure = false
    let origin = try XCTUnwrap(environment["OPENCODE_TEST_ORIGIN_SESSION"], "Set OPENCODE_TEST_ORIGIN_SESSION")
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", origin]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let title = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 30))
    let originTitle = title.label
    let branch = app.staticTexts["conversation-header-subtitle"]
    XCTAssertTrue(branch.waitForExistence(timeout: 20))
    let originBranch = branch.label
    let model = app.buttons["model-picker"]
    XCTAssertTrue(model.waitForExistence(timeout: 20))
    let originModel = try XCTUnwrap(model.value as? String)

    let create = app.openConversationOptions(expect: "Nova sessão")
    let first = app.buttons.matching(NSPredicate(format: "label IN %@",
      ["Nova sessão", "Buscar na conversa", "Renomear", "Detalhes da sessão"])).allElementsBoundByIndex
      .min { $0.frame.minY < $1.frame.minY }
    XCTAssertEqual(first?.label, "Nova sessão")
    shot("menu")
    create.tap()

    let project = app.buttons["new-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 20))
    let name = environment["OPENCODE_TEST_ORIGIN_PROJECT"]
    if let name {
      XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label CONTAINS %@", name), object: project)], timeout: 20), .completed)
    }
    // A chat has no checkout; its header subtitle is the model instead of a branch.
    if name != "Chats" {
      let directory = app.buttons["new-directory"]
      XCTAssertTrue(directory.waitForExistence(timeout: 20))
      XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label CONTAINS %@", originBranch), object: directory)], timeout: 20), .completed)
    }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", originModel), object: app.buttons["model-picker"])], timeout: 20),
      .completed)
    shot("new-session")

    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText("Responda apenas: nova ok")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts["Responda apenas: nova ok"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'nova ok'")).firstMatch
      .waitForExistence(timeout: 120))
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label BEGINSWITH %@", originBranch),
      object: app.staticTexts["conversation-header-subtitle"])], timeout: 20), .completed)
    shot("sent")
    app.buttons["Voltar"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", originTitle), object: app.staticTexts["conversation-header-title"])],
      timeout: 10), .completed)
  }

  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "menu-new-session-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
