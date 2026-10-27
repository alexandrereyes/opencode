import XCTest

@MainActor final class NewSessionTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
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
    // A repository chip preselects its project.
    XCTAssertTrue(app.buttons["new-project"].label.contains("abacato-v2"))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    if app.buttons["Continuar"].exists { app.buttons["Continuar"].tap() }
    if app.buttons["new-base"].exists {
      chooseDestination("new-root", app)
    }
    keyboardSettled(app)
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    shot("n1-keyboard")
    app.buttons["new-project"].tap()
    XCTAssertTrue(app.navigationBars["Projeto"].waitForExistence(timeout: 5))
    keyboardHidden(app)
    shot("n2-project")
    app.buttons["Adicionar projeto"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForExistence(timeout: 5))
    app.buttons["Cancelar"].tap()
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
    keyboardHidden(app)
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
    input.typeText("Revisa a navegação do app iOS")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    keyboardSettled(app)
    shot("n4-new-worktree")
    app.switches["mcp-safari-devtools"].tap()
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
  private func keyboardHidden(_ app: XCUIApplication) {
    let keyboard = app.keyboards.firstMatch
    let hidden = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        !keyboard.exists || keyboard.frame.minY >= app.frame.maxY
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
  }
  private func composerFocused(_ app: XCUIApplication) {
    keyboardSettled(app)
    let input = app.textViews["conversation-composer"]
    let before = input.value as? String ?? ""
    app.typeText("x")
    XCTAssertEqual(input.value as? String, before + "x")
    app.typeText(XCUIKeyboardKey.delete.rawValue)
    XCTAssertEqual(input.value as? String, before)
  }
  private func dismissSelector(_ title: String, _ app: XCUIApplication) {
    let bar = app.navigationBars[title]
    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
      forDuration: 0.1,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    composerFocused(app)
  }
  func test04SelectorKeyboardDismissalAndComposerRestoration() throws {
    let app = try launch()
    defer { app.terminate() }
    openNewSession(app)
    ready(app)
    chooseProject("abacato-v2", app)
    chooseDestination("new-root", app)
    composerFocused(app)

    app.buttons["new-project"].tap()
    XCTAssertTrue(app.navigationBars["Projeto"].waitForExistence(timeout: 5))
    keyboardHidden(app)
    shot("n2-project")
    dismissSelector("Projeto", app)
    app.buttons["new-project"].tap()
    XCTAssertTrue(app.buttons["new-project-opencode2"].waitForExistence(timeout: 5))
    keyboardHidden(app)
    app.buttons["new-project-opencode2"].tap()
    ready(app)
    composerFocused(app)
    chooseProject("abacato-v2", app)
    composerFocused(app)

    app.buttons["new-directory"].tap()
    XCTAssertTrue(app.navigationBars["Diretório"].waitForExistence(timeout: 5))
    keyboardHidden(app)
    let expected = Set(
      ["neon-mountain", "feat/redesign-identidade", "cosmic-moon", "calm-mountain", "gentle-wolf"]
        .map { "new-worktree-" + $0 })
    XCTAssertEqual(
      Set(
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'new-worktree-'"))
          .allElementsBoundByIndex.map(\.identifier)), expected)
    XCTAssertFalse(app.staticTexts["glowing-meadow"].exists)
    shot("n3-directory")
    dismissSelector("Diretório", app)
    chooseDestination("new-worktree-neon-mountain", app)
    composerFocused(app)
    chooseDestination("new-create", app)
    composerFocused(app)

    app.buttons["new-base"].tap()
    XCTAssertTrue(app.navigationBars["Branch base"].waitForExistence(timeout: 5))
    keyboardSettled(app)
    // The base sheet deliberately owns its keyboard; typing must target search, not the composer.
    app.typeText("main")
    XCTAssertEqual(app.textFields["selector-search"].value as? String, "main")
    shot("base-branches")
    dismissSelector("Branch base", app)
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, "")
    app.buttons["new-base"].tap()
    XCTAssertTrue(app.buttons["base-main"].waitForExistence(timeout: 10))
    keyboardSettled(app)
    app.buttons["base-main"].tap()
    ready(app)
    composerFocused(app)
    app.typeText("Revisa a navegação do app iOS")
    XCTAssertEqual(
      app.textViews["conversation-composer"].value as? String, "Revisa a navegação do app iOS")
    // Unicode injection temporarily hides the simulator keyboard; relaunch the real saved draft
    // rather than retapping an already focused editor and opening its native edit menu.
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["Nova sessão"].waitForExistence(timeout: 20))
    openNewSession(app)
    ready(app)
    XCTAssertEqual(
      app.textViews["conversation-composer"].value as? String, "Revisa a navegação do app iOS")
    keyboardSettled(app)
    shot("n4-new-worktree")
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
    if let value = input.value as? String, !value.isEmpty {
      input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
    chooseProject("ios-conversation", app)
    chooseDestination("new-root", app)
    submit("Responda apenas OK, sem ferramentas. Onda 9 raiz.", app)
    openNewSession(app)
    ready(app)
    chooseProject("abacato-v2", app)
    chooseDestination("new-worktree-neon-mountain", app)
    submit("Responda apenas OK, sem ferramentas. Onda 9 existente.", app)
    openNewSession(app)
    ready(app)
    chooseProject("abacato-v2", app)
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
