import XCTest

/// Reproduces the opencode2 layout: a Git root checked out on a non-default branch (`custom`), a detached
/// worktree, a named one and a stored worktree whose folder was removed outside OpenCode.
/// Requires `OPENCODE_TEST_GIT_REPO` (the root) and `OPENCODE_TEST_STALE_WORKTREE` (the removed folder name).
@MainActor final class NewSessionWorktreeTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func wait(_ element: XCUIElement, _ format: String, _ value: CVarArg) -> Bool {
    XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: format, value), object: element)
      ], timeout: 30) == .completed
  }

  func testRootOnBranchOffersExistingAndNewWorktrees() throws {
    continueAfterFailure = false
    let repo = try XCTUnwrap(environment["OPENCODE_TEST_GIT_REPO"])
    let stale = try XCTUnwrap(environment["OPENCODE_TEST_STALE_WORKTREE"])
    let name = URL(fileURLWithPath: repo).lastPathComponent
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    app.showSessions()
    app.buttons["Nova sessão"].tap()
    let project = app.buttons["new-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 20))
    project.tap()
    if app.buttons["new-project-" + name].waitForExistence(timeout: 5) {
      app.buttons["new-project-" + name].tap()
    } else {
      app.navigationBars["Projeto"].buttons["new-project-add"].tap()
      let path = app.textFields["add-project-path"]
      XCTAssertTrue(wait(path, "value == %@", "~/Dev/"))
      path.tap()
      path.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + repo + "/")
      let submit = app.buttons["add-project-submit"]
      XCTAssertTrue(wait(submit, "enabled == %@", NSNumber(value: true)))
      submit.tap()
    }
    XCTAssertTrue(wait(project, "label CONTAINS %@", name))
    let directory = app.buttons["new-directory"]
    XCTAssertTrue(directory.waitForExistence(timeout: 20))
    if directory.label.contains("Nova worktree") {
      directory.tap()
      XCTAssertTrue(app.buttons["new-root"].waitForExistence(timeout: 10))
      app.buttons["new-root"].tap()
    }
    // The root is labeled by its checkout branch, as on the web; it is still the directory selector.
    XCTAssertTrue(wait(directory, "label == %@", "Diretório: custom"))
    XCTAssertTrue(wait(directory, "enabled == %@", NSNumber(value: true)))
    shot("worktree-nova-sessao")

    directory.tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForExistence(timeout: 5))
    let create = app.navigationBars["Diretório"].buttons["new-create"]
    XCTAssertTrue(create.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["new-worktree-feature-a"].waitForExistence(timeout: 10))
    shot("worktree-diretorio")
    XCTAssertTrue(app.navigationBars["Diretório"].staticTexts["Nova worktree"].exists)
    XCTAssertTrue(app.buttons["new-worktree-wt-detached"].exists)
    XCTAssertFalse(app.buttons["new-worktree-" + stale].exists)
    XCTAssertFalse(app.buttons["new-worktrees-error"].exists)

    create.tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForNonExistence(timeout: 10))
    let base = app.buttons["new-base"]
    XCTAssertTrue(base.waitForExistence(timeout: 10))
    XCTAssertTrue(wait(base, "label CONTAINS %@", "a partir de custom"))
    XCTAssertTrue(directory.label.contains("Nova worktree"))
    shot("worktree-nova-selecionada")

    directory.tap()
    XCTAssertTrue(app.buttons["new-worktree-wt-detached"].waitForExistence(timeout: 10))
    app.buttons["new-worktree-wt-detached"].tap()
    XCTAssertTrue(wait(directory, "label == %@", "Diretório: wt-detached"))
    directory.tap()
    XCTAssertTrue(app.buttons["new-root"].waitForExistence(timeout: 10))
    app.buttons["new-root"].tap()
    XCTAssertTrue(wait(directory, "label == %@", "Diretório: custom"))
  }
}
