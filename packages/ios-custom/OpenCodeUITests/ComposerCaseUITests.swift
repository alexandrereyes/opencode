import XCTest

/// Needs an isolated sandbox prepared by `script/test-composer-case.py`: a conversation in a fake repository with
/// `README.md` and `src/SafariBridge.ts`, a Session titled "Sessão Revisão Especial", an archived one, two titled
/// "Gemea Repetida" in different directories, the snippet `commit-push-pr`, and the skill, command and agent named by
/// the environment. Only the `&` case sends a prompt.
@MainActor final class ComposerCaseUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// `@` lists no archived session, and two sessions with one title each show their directory and age.
  func testSessionMentionsSkipArchivedAndTellRepeatedTitlesApart() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
                           "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_CASE_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    try app.requireSandbox()
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))
    editor.tap()
    editor.typeText("@Arquivada")
    XCTAssertTrue(app.staticTexts["Nenhum item correspondente"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["suggestion-" + (try XCTUnwrap(environment["OPENCODE_CASE_ARCHIVED"]))].exists)
    shot("mention-archived-hidden")
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
    editor.typeText("@Gemea")
    let twins = try ["OPENCODE_CASE_TWIN_A", "OPENCODE_CASE_TWIN_B"].map { app.buttons["suggestion-" + (try XCTUnwrap(environment[$0]))] }
    XCTAssertTrue(twins[0].waitForExistence(timeout: 10))
    XCTAssertTrue(twins[1].exists)
    // Each repeated title carries its directory and relative age, like the Sessões rows.
    for directory in ["composer-case", "composer-twin"] {
      XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", directory + " · ")).firstMatch
        .waitForExistence(timeout: 5), directory)
    }
    shot("mention-repeated-titles")
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
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
      ("&readme", "README.md"), ("&README", "README.md"), ("&SAFARIBRIDGE", "src/SafariBridge.ts"),
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

  /// Files moved from `@` to `&`; the script then checks the sent message's file reference on the server.
  func testAmpersandSendsTheFileReferenceAtNoLongerLists() throws {
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
    let agent = try XCTUnwrap(environment["OPENCODE_CASE_AGENT"])
    let readme = app.buttons["suggestion-README.md"]
    editor.typeText("@")
    XCTAssertTrue(app.buttons["suggestion-" + agent].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["suggestion-" + (try XCTUnwrap(environment["OPENCODE_CASE_TARGET"]))].exists)
    XCTAssertFalse(readme.exists)
    XCTAssertFalse(app.staticTexts["Arquivos"].exists)
    shot("at-without-files")
    editor.typeText("readme")
    XCTAssertTrue(app.staticTexts["Nenhum item correspondente"].waitForExistence(timeout: 10))
    XCTAssertFalse(readme.exists)
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
    // `!` and a glued `&` are prose.
    editor.typeText("!READ R&D")
    XCTAssertFalse(app.staticTexts["Arquivos"].waitForExistence(timeout: 2))
    XCTAssertFalse(readme.exists)
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
    editor.typeText("Leia &READ")
    XCTAssertTrue(readme.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Arquivos"].exists)
    shot("ampersand-files")
    readme.tap()
    XCTAssertTrue(readme.waitForNonExistence(timeout: 5))
    editor.typeText("e responda ok!")
    XCTAssertFalse(app.staticTexts["Arquivos"].waitForExistence(timeout: 2))
    shot("ampersand-token")
    let send = app.buttons["composer-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 10) && send.isEnabled)
    send.tap()
    XCTAssertTrue(app.staticTexts["Leia @README.md e responda ok!"].waitForExistence(timeout: 30))
    shot("ampersand-sent")
  }
}
