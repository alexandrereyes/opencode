import XCTest

/// Requires `OPENCODE_TEST_ADD_PROJECT_DIR`: an isolated folder containing an `alvo` subfolder.
@MainActor final class AddProjectTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func waitValue(_ element: XCUIElement, _ value: String) -> Bool {
    XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", value), object: element)
      ], timeout: 15) == .completed
  }
  private func openExplorer(_ app: XCUIApplication) {
    if app.buttons["new-project"].waitForExistence(timeout: 10) {
      app.buttons["new-project"].tap()
      XCTAssertTrue(app.navigationBars["Projeto"].waitForExistence(timeout: 5))
      let add = app.navigationBars["Projeto"].buttons["new-project-add"]
      XCTAssertTrue(add.waitForExistence(timeout: 5))
      shot("projeto")
      add.tap()
    } else {
      app.buttons["Adicionar projeto"].firstMatch.tap()
    }
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForExistence(timeout: 5))
  }
  private func replace(_ field: XCUIElement, with text: String) {
    field.tap()
    let current = (field.value as? String) ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
    field.typeText(text)
  }

  func testBrowseFromDevGoUpAndAddProjects() throws {
    continueAfterFailure = false
    let base = try XCTUnwrap(environment["OPENCODE_TEST_ADD_PROJECT_DIR"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    app.showSessions()
    app.buttons["Nova sessão"].tap()
    openExplorer(app)

    let path = app.textFields["add-project-path"]
    XCTAssertTrue(path.waitForExistence(timeout: 10))
    XCTAssertTrue(waitValue(path, "~/Dev/"))
    let up = app.buttons["add-project-up"]
    XCTAssertTrue(up.waitForExistence(timeout: 10))
    let firstFolder = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'add-project-folder-'")
    ).firstMatch
    XCTAssertTrue(firstFolder.waitForExistence(timeout: 15))
    XCTAssertLessThan(up.frame.minY, firstFolder.frame.minY)
    shot("explorer-dev")

    up.tap()
    XCTAssertTrue(waitValue(path, "~/"))
    XCTAssertTrue(firstFolder.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["add-project-submit"].isEnabled)
    shot("explorer-home")
    // The trailing segment filters the listed folders by prefix, as on the web.
    path.tap()
    path.typeText("De")
    let dev = app.buttons["add-project-folder-Dev"]
    XCTAssertTrue(dev.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["add-project-up"].exists)
    shot("explorer-filter")
    dev.tap()
    XCTAssertTrue(waitValue(path, "~/Dev/"))

    replace(path, with: base + "/")
    let quick = app.buttons["add-project-quick-alvo"]
    XCTAssertTrue(quick.waitForExistence(timeout: 15))
    shot("explorer-probe")
    quick.tap()
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForNonExistence(timeout: 15))
    let project = app.buttons["new-project"]
    XCTAssertTrue(project.waitForExistence(timeout: 20))
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'alvo'"), object: project)
        ], timeout: 20) == .completed)

    openExplorer(app)
    replace(path, with: base + "/criado")
    let submit = app.buttons["add-project-submit"]
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Criar e adicionar' AND enabled == true"),
            object: submit)
        ], timeout: 15) == .completed)
    shot("explorer-create")
    submit.tap()
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForNonExistence(timeout: 15))
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'criado'"), object: project)
        ], timeout: 20) == .completed)

    project.tap()
    XCTAssertTrue(app.buttons["new-project-alvo"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["new-project-criado"].exists)
    shot("projeto-depois")
    app.navigationBars["Projeto"].buttons["new-project-add"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForExistence(timeout: 5))
    replace(path, with: base + "/")
    XCTAssertTrue(app.staticTexts["Adicionado"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["add-project-quick-alvo"].exists)
    app.buttons["Cancelar"].tap()
  }

  /// Uses the server home's `Dev/opencode2` checkout as a Git project; Nova worktree creates nothing until sending.
  func testNewWorktreeDestinationInDirectoryHeader() throws {
    continueAfterFailure = false
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
    if app.buttons["new-project-opencode2"].waitForExistence(timeout: 5) {
      app.buttons["new-project-opencode2"].tap()
    } else {
      // Quick add straight from the initial ~/Dev listing.
      app.navigationBars["Projeto"].buttons["new-project-add"].tap()
      let path = app.textFields["add-project-path"]
      XCTAssertTrue(waitValue(path, "~/Dev/"))
      // Filter so the lazily loaded list materializes the row.
      path.tap()
      path.typeText("opencode2")
      let quick = app.buttons["add-project-quick-opencode2"]
      XCTAssertTrue(quick.waitForExistence(timeout: 15))
      quick.tap()
    }
    let directory = app.buttons["new-directory"]
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'opencode2' AND enabled == true"),
            object: project)
        ], timeout: 30) == .completed)
    XCTAssertTrue(directory.waitForExistence(timeout: 20))
    if directory.label.contains("Nova worktree") {
      directory.tap()
      XCTAssertTrue(app.buttons["new-root"].waitForExistence(timeout: 10))
      app.buttons["new-root"].tap()
    }

    directory.tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForExistence(timeout: 5))
    let create = app.navigationBars["Diretório"].buttons["new-create"]
    XCTAssertTrue(create.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["new-root"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["new-root"].images["checkmark"].exists)
    shot("diretorio")
    create.tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["new-base"].waitForExistence(timeout: 10))
    XCTAssertTrue(directory.label.contains("Nova worktree"))
    shot("nova-worktree-seletor")

    directory.tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForExistence(timeout: 5))
    XCTAssertEqual(create.label, "Nova worktree selecionada")
    XCTAssertFalse(app.buttons["new-root"].images["checkmark"].exists)
    XCTAssertFalse(app.cells.images["checkmark"].exists)
    XCTAssertTrue(app.staticTexts["Nova worktree selecionada: ela será criada ao enviar."].exists)
    shot("diretorio-nova-worktree")
    create.tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForNonExistence(timeout: 10))

    // The destination category is remembered per project for the next implicit selection.
    project.tap()
    XCTAssertTrue(app.buttons["new-project-alvo"].waitForExistence(timeout: 5))
    app.buttons["new-project-alvo"].tap()
    XCTAssertTrue(app.buttons["new-base"].waitForNonExistence(timeout: 10))
    project.tap()
    XCTAssertTrue(app.buttons["new-project-opencode2"].waitForExistence(timeout: 5))
    app.buttons["new-project-opencode2"].tap()
    XCTAssertTrue(app.buttons["new-base"].waitForExistence(timeout: 20))
    XCTAssertTrue(directory.label.contains("Nova worktree"))

    directory.tap()
    XCTAssertTrue(app.buttons["new-root"].waitForExistence(timeout: 10))
    app.buttons["new-root"].tap()
    XCTAssertTrue(app.buttons["new-base"].waitForNonExistence(timeout: 10))
  }
}
