import XCTest

@MainActor final class SessionReadingTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_" + role]),
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    if environment["OPENCODE_TEST_MENU_DIAGNOSTICS"] == "1" { app.launchArguments.append("-OpenCodeMenuDiagnostics") }
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 20), .completed)
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testMenuRenameAndArchiveOwnSession() throws {
    let app = try launch("SESSION_ACTIONS")
    app.buttons["Mais opções"].tap()
    screenshot("menu")
    app.buttons["Renomear"].tap()
    XCTAssertTrue(app.alerts["Renomear sessão"].waitForExistence(timeout: 5))
    screenshot("rename")
    let field = app.alerts.textFields.firstMatch
    let old = field.value as? String ?? ""
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Onda 5 — renomeada")
    // Unicode typeText temporarily hides the software keyboard; restore it before
    // resolving the alert button's frame, which moves when the keyboard appears.
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    screenshot("rename-edited")
    app.alerts.buttons["Salvar"].tap()
    screenshot("rename-after-save")
    XCTAssertTrue(app.staticTexts["Onda 5 — renomeada"].waitForExistence(timeout: 10))
    app.buttons["Voltar"].tap()
    let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 5 — renomeada'")).firstMatch
    XCTAssertTrue(renamed.waitForExistence(timeout: 15))
    screenshot("renamed-list")
    app.revealSessionRow(renamed)
    renamed.tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    app.buttons["Mais opções"].tap()
    app.buttons["Arquivar"].tap()
    screenshot("archive-confirmation")
    app.buttons["Arquivar"].tap()
    XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 15))
    screenshot("archived-toast")
  }
  func testDetailsRootAndChild() throws {
    for role in ["A", "CHILD"] {
      let app = try launch(role)
      app.buttons["Mais opções"].tap()
      if role == "CHILD" { XCTAssertFalse(app.buttons["Arquivar"].exists) }
      app.buttons["Detalhes da sessão"].tap()
      XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
      XCTAssertTrue(app.staticTexts["Projeto"].exists)
      screenshot("details-" + role.lowercased())
      app.swipeUp(velocity: .slow)
      screenshot("details-services-" + role.lowercased())
      for (label, name) in [("Plugins", "plugins"), ("Skills", "skills"), ("LSP · configuração", "lsp")] {
        let section = app.staticTexts[label].firstMatch
        for _ in 0..<12 {
          if section.exists && section.isHittable { break }
          app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(section.exists && section.isHittable)
        screenshot("details-" + name + "-" + role.lowercased())
      }
      app.buttons["Fechar"].tap()
      app.terminate()
    }
  }
  func testSearchLoadedAndOlderPages() throws {
    var app = try launch("C")
    if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
    app.buttons["Voltar"].tap()
    app.terminate()
    app = try launch("C")
    app.buttons["Mais opções"].tap()
    app.buttons["Buscar na conversa"].tap()
    let field = app.textFields["conversation-search"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("revisao")
    let counter = app.staticTexts["search-counter"]
    wait(NSPredicate(format: "label BEGINSWITH '1 de '"), on: counter)
    screenshot("search-results")
    app.buttons["Próximo resultado"].tap()
    wait(NSPredicate(format: "label BEGINSWITH '2 de '"), on: counter)
    app.buttons["Resultado anterior"].tap()
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "revisao 1 concluida")
    wait(NSPredicate(format: "label == '0 de 0'"), on: counter)
    screenshot("search-older-offer")
    app.buttons["Buscar em mensagens mais antigas"].tap()
    wait(NSPredicate(format: "label == '1 de 1'"), on: counter)
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Revisão 1 concluída'")).firstMatch.waitForExistence(timeout: 10))
    screenshot("search-older-result")
    app.buttons["Cancelar"].tap()
    screenshot("search-closed-position")
    app.buttons["Voltar"].tap()
    app.terminate()
    app = try launch("C")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'PR fictício'")).firstMatch.waitForExistence(timeout: 10))
  }
  func testMissingDirectoryKeepsHistoryAndBlocksComposer() throws {
    let app = try launch("SESSION_MISSING")
    XCTAssertTrue(app.staticTexts["Diretório indisponível"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.textViews["conversation-composer"].exists)
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Histórico preservado'")).firstMatch.exists)
    screenshot("missing-directory")
    app.buttons["Tentar novamente"].tap()
    XCTAssertTrue(app.staticTexts["Diretório indisponível"].exists)
  }
}
