import XCTest

/// Needs an isolated sandbox prepared by `script/test-composer-case.py`: a conversation in a fake repository with
/// `README.md` and `src/SafariBridge.ts`, a Session titled "Sessão Revisão Especial", the snippet `commit-push-pr`,
/// and the skill, command and agent named by the environment. Nothing is sent.
@MainActor final class ComposerCaseUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testEveryTriggerIgnoresCase() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
                           "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_CASE_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    editor.tap()
    let skill = try XCTUnwrap(environment["OPENCODE_CASE_SKILL"])
    let command = try XCTUnwrap(environment["OPENCODE_CASE_COMMAND"])
    let agent = try XCTUnwrap(environment["OPENCODE_CASE_AGENT"])
    let target = try XCTUnwrap(environment["OPENCODE_CASE_TARGET"])
    let cases: [(String, String)] = [
      ("@readme", "README.md"), ("@README", "README.md"), ("@SAFARIBRIDGE", "src/SafariBridge.ts"),
      ("@especial", target), ("@ESPECIAL", target), ("@SESSÃO", target), ("@sessão", target),
      ("@" + agent.uppercased(), agent), ("$" + skill.uppercased(), skill), ("$" + skill.capitalized, skill),
      ("#COMMIT", "snip-commit"), ("#Commit", "snip-commit"), ("#commit", "snip-commit"),
      ("/" + command.uppercased(), command), ("/" + command.capitalized, command),
    ]
    for (query, id) in cases {
      editor.typeText(query)
      XCTAssertTrue(app.buttons["suggestion-" + id].waitForExistence(timeout: 10), "\(query) should offer \(id)")
      if query == "@SESSÃO" || query == "#COMMIT" { shot("case-" + query.dropFirst().lowercased()) }
      editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: query.count))
      XCTAssertTrue(app.buttons["suggestion-" + id].waitForNonExistence(timeout: 10))
    }
    // Return still picks the first, already loaded suggestion.
    editor.typeText("#COMMIT")
    XCTAssertTrue(app.buttons["suggestion-snip-commit"].waitForExistence(timeout: 10))
    editor.typeText("\n")
    XCTAssertTrue(app.buttons["suggestion-snip-commit"].waitForNonExistence(timeout: 5))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "#COMMIT"), object: editor)],
        timeout: 5), .completed)
    shot("case-return")
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
  }
}
