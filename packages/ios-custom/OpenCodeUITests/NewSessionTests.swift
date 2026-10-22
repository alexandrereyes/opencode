import XCTest

@MainActor final class NewSessionTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    return app
  }
  private func openNewSession(_ app: XCUIApplication) {
    if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
    app.buttons["Nova sessão"].tap()
    if !app.buttons["new-project"].waitForExistence(timeout: 3),
      app.navigationBars["Sessões"].exists, !app.staticTexts["Nova sessão"].exists
    {
      // A completion banner can cover the toolbar just after leaving a sent session.
      if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
      app.buttons["Nova sessão"].tap()
    }
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func ready(_ app: XCUIApplication) {
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 20))
    XCTAssertTrue(
      NSPredicate(format: "enabled == true").evaluate(with: app.buttons["new-project"])
        || XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(format: "enabled == true"), object: app.buttons["new-project"])
          ], timeout: 30) == .completed
    )
  }
  private func chooseProject(_ name: String, _ app: XCUIApplication) {
    app.buttons["new-project"].tap()
    let project = app.buttons["new-project-" + name]
    XCTAssertTrue(project.waitForExistence(timeout: 5))
    project.tap()
    ready(app)
    XCTAssertTrue(app.buttons["new-project"].label.contains(name))
  }
  private func chooseDestination(_ id: String, _ app: XCUIApplication) {
    app.buttons["new-directory"].tap()
    XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
    app.buttons[id].tap()
    ready(app)
  }
  private func submit(_ text: String, _ app: XCUIApplication) {
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(text)
    XCTAssertTrue(app.buttons["Enviar mensagem"].isEnabled)
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
    shot(
      text.contains("raiz")
        ? "sent-root" : text.contains("existente") ? "sent-existing" : "sent-new")
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Nova sessão"].exists)
  }
  func test01SelectorsPreviewAndPersistentDraft() throws {
    let app = try launch()
    defer { app.terminate() }
    let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'abacato-v2'")).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 10))
    chip.tap()
    openNewSession(app)
    ready(app)
    XCTAssertTrue(app.buttons["new-project"].label.contains("abacato-v2"))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    if app.buttons["Continuar"].exists { app.buttons["Continuar"].tap() }
    if app.buttons["new-base"].exists {
      chooseDestination("new-root", app)
      app.textViews["conversation-composer"].tap()
    }
    keyboardSettled(app)
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    shot("n1-keyboard")
    app.buttons["new-project"].tap()
    shot("n2-project")
    app.buttons["Adicionar projeto"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForExistence(timeout: 5))
    app.buttons["Concluir"].tap()
    ready(app)
    app.buttons["new-project"].tap()
    app.buttons["new-project-opencode2"].tap()
    ready(app)
    XCTAssertTrue(app.buttons["new-project"].label.contains("opencode2"))
    app.buttons["Adicionar"].tap()
    app.buttons["Expandir compositor"].tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForExistence(timeout: 5))
    app.buttons["Recolher"].tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForNonExistence(timeout: 5))
    ready(app)
    XCTAssertTrue(app.buttons["new-project"].label.contains("opencode2"))
    chooseProject("abacato-v2", app)
    chooseDestination("new-root", app)
    let safe = app.switches["mcp-safari-devtools"]
    XCTAssertTrue(safe.waitForExistence(timeout: 10))
    safe.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Desativado'"), object: safe)
        ], timeout: 20), .completed)
    safe.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Ativado'"), object: safe)
        ], timeout: 20), .completed)
    app.buttons["new-directory"].tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["Buscar worktrees"].exists)
    shot("n3-directory")
    app.buttons["new-create"].tap()
    ready(app)
    XCTAssertTrue(app.staticTexts["Vale quando a worktree for criada"].exists)
    app.buttons["new-base"].tap()
    XCTAssertTrue(app.buttons["base-feat/redesign-identidade"].waitForExistence(timeout: 10))
    keyboardSettled(app)
    shot("base-branches")
    app.buttons["base-main"].tap()
    ready(app)
    let input = app.textViews["conversation-composer"]
    input.tap()
    input.typeText("Revisa a navegação do app iOS")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    keyboardSettled(app)
    shot("n4-new-worktree")
    app.switches["mcp-safari-devtools"].tap()
    input.tap()
    keyboardSettled(app)
    shot("mcp-preview-off")
    app.buttons["new-base"].tap()
    XCTAssertTrue(app.buttons["base-feat/redesign-identidade"].waitForExistence(timeout: 10))
    app.buttons["base-feat/redesign-identidade"].tap()
    ready(app)
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 10))
    // Reopen without a repository filter: the explicit draft survives independently of lastProject.
    app.buttons["Todas"].firstMatch.tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["Nova sessão"].waitForExistence(timeout: 20))
    openNewSession(app)
    ready(app)
    XCTAssertEqual(
      app.textViews["conversation-composer"].value as? String, "Revisa a navegação do app iOS")
    XCTAssertTrue(app.buttons["new-base"].label.contains("feat/redesign-identidade"))
    shot("restored-draft")
  }
  private func keyboardSettled(_ app: XCUIApplication) {
    let keyboard = app.keyboards.firstMatch
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        keyboard.exists && keyboard.frame.minY < app.frame.height - 280
          && keyboard.frame.maxY <= app.frame.maxY + 1
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
  }
  func test02InvalidBaseKeepsDraftAndShowsToast() throws {
    let app = try launch()
    defer { app.terminate() }
    openNewSession(app)
    ready(app)
    XCTAssertTrue(app.buttons["new-base"].label.contains("onda9-invalid-base"))
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["action-toast"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["new-project"].exists)
    XCTAssertEqual(
      app.textViews["conversation-composer"].value as? String, "Revisa a navegação do app iOS")
    shot("error-toast")
  }
  func test03SendRootExistingAndNewWorktree() throws {
    let app = try launch()
    defer { app.terminate() }
    openNewSession(app)
    ready(app)
    let input = app.textViews["conversation-composer"]
    input.tap()
    if let value = input.value as? String, !value.isEmpty {
      input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
    chooseProject("ios-conversation", app)
    chooseDestination("new-root", app)
    submit("Responda apenas OK, sem ferramentas. Onda 9 raiz.", app)
    guard !theme.hasSuffix("light") else { return }
    openNewSession(app)
    ready(app)
    chooseProject("abacato-v2", app)
    chooseDestination("new-worktree-neon-mountain", app)
    submit("Responda apenas OK, sem ferramentas. Onda 9 existente.", app)
    openNewSession(app)
    ready(app)
    chooseDestination("new-create", app)
    app.buttons["new-base"].tap()
    XCTAssertTrue(app.buttons["base-feat/redesign-identidade"].waitForExistence(timeout: 10))
    keyboardSettled(app)
    app.buttons["base-feat/redesign-identidade"].tap()
    ready(app)
    // Only safari-devtools is allowed to change, including in the destination preview.
    app.switches["mcp-safari-devtools"].tap()
    submit("Responda apenas OK, sem ferramentas. Onda 9 nova.", app)
  }
}
