import XCTest

@MainActor final class SessionReadingTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
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
    let rename = app.openConversationOptions(expect: "Renomear")
    screenshot("menu")
    rename.tap()
    XCTAssertTrue(app.alerts["Renomear sessão"].waitForExistence(timeout: 5))
    screenshot("rename")
    app.assertRenameTitleSelected()
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
    app.revealSessionRow(renamed)
    XCTAssertTrue(renamed.waitForExistence(timeout: 15))
    screenshot("renamed-list")
    renamed.tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    app.openConversationOptions(expect: "Arquivar").tap()
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
      func visible(_ element: XCUIElement) -> Bool {
        element.exists && element.frame.height > 0
          && element.frame.minY >= app.navigationBars["Detalhes da sessão"].frame.maxY
          && element.frame.maxY <= app.frame.maxY - 30
      }
      func scroll(down: Bool = false) {
        // Full fast swipes can skip and virtualize a short section header between checks.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.46 : 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.72 : 0.46))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
      }
      let project = app.staticTexts["Projeto"]
      for _ in 0..<5 {
        if visible(project) { break }
        if project.exists && project.frame.minY < app.navigationBars["Detalhes da sessão"].frame.maxY {
          scroll(down: true)
          continue
        }
        scroll()
      }
      XCTAssertTrue(visible(project))
      screenshot("details-" + role.lowercased())
      scroll()
      screenshot("details-services-" + role.lowercased())
      for (label, name) in [("Plugins", "plugins"), ("Skills", "skills"), ("LSP · configuração", "lsp")] {
        let section = app.staticTexts[label].firstMatch
        for _ in 0..<30 {
          if visible(section) { break }
          if section.exists && section.frame.minY < app.navigationBars["Detalhes da sessão"].frame.maxY {
            scroll(down: true)
            continue
          }
          scroll()
        }
        XCTAssertTrue(visible(section))
        screenshot("details-" + name + "-" + role.lowercased())
      }
      app.buttons["Fechar"].tap()
      app.terminate()
    }
  }
  func testSearchLoadedAndOlderPages() throws {
    var app = try launch("C")
    if app.buttons["Ir para a mais recente"].exists { app.buttons["Ir para a mais recente"].tap() }
    app.buttons["Voltar"].tap()
    app.terminate()
    app = try launch("C")
    app.openConversationOptions(expect: "Buscar na conversa").tap()
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
    let close = app.buttons["conversation-search-close"]
    var previous: CGRect?
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let frame = close.frame
      defer { previous = frame }
      return previous == frame && close.isHittable
    }, object: nil)], timeout: 5), .completed)
    close.tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 5))
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
