import XCTest

/// Needs four owned sessions from `script/test-session-selection.py` (`OPENCODE_SELECT_A`…`D`): A and B are archived
/// in a batch, C and D deleted in a batch.
@MainActor final class SessionSelectionTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "select-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testSelectArchiveAndDeleteInBatches() throws {
    let ids = try ["A", "B", "C", "D"].map { try XCTUnwrap(environment["OPENCODE_SELECT_" + $0]) }
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let rows = ids.map { app.buttons["session-row-" + $0] }
    let menu = app.buttons["sessions-selection-menu"]
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))
    try app.requireSandbox()
    app.revealSessionRow(rows[0])
    XCTAssertFalse(menu.exists, "O ⋯ só aparece no modo de seleção.")

    // Outside the mode the swipe and the long-press menu keep working.
    rows[0].swipeLeft()
    XCTAssertTrue(app.buttons["Renomear"].waitForExistence(timeout: 5))
    rows[0].swipeRight()
    XCTAssertTrue(app.buttons["Renomear"].waitForNonExistence(timeout: 5))
    select(rows[0], app)
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    let voice = app.buttons["voice-start"]
    XCTAssertLessThanOrEqual(menu.frame.maxX, voice.frame.minX, "O ⋯ fica à esquerda da voz.")
    XCTAssertEqual(abs(menu.frame.midY - voice.frame.midY) < 2, true)
    XCTAssertTrue(rows[0].isSelected)
    XCTAssertEqual(app.staticTexts["sessions-selection-count"].label, "1 selecionada")
    shot("started")

    // "⋯" → Cancelar leaves the mode.
    menu.tap()
    XCTAssertTrue(app.buttons["Arquivar (1)"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Excluir (1)"].exists)
    shot("menu")
    app.buttons["Cancelar"].tap()
    XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
    XCTAssertFalse(rows[0].isSelected)
    XCTAssertFalse(app.buttons["sessions-selection-done"].exists)

    // OK also leaves it.
    select(rows[0], app)
    app.buttons["sessions-selection-done"].tap()
    XCTAssertTrue(menu.waitForNonExistence(timeout: 5))

    // Tapping toggles instead of opening; swipe and long press are off.
    select(rows[0], app)
    app.revealSessionRow(rows[1])
    rows[1].tap()
    XCTAssertTrue(rows[1].isSelected)
    XCTAssertEqual(app.staticTexts["sessions-selection-count"].label, "2 selecionadas")
    XCTAssertFalse(app.navigationBars.buttons["Voltar"].exists, "Tocar não abre a conversa no modo de seleção.")
    rows[1].swipeLeft()
    XCTAssertFalse(app.buttons["Renomear"].waitForExistence(timeout: 2))
    rows[1].press(forDuration: 1.2)
    XCTAssertFalse(app.buttons["Abrir sessão"].waitForExistence(timeout: 2))
    if !rows[1].isSelected { rows[1].tap() }
    XCTAssertTrue(rows[0].isSelected && rows[1].isSelected)
    shot("two-selected")

    try app.requireSandbox()
    menu.tap()
    app.buttons["Arquivar (2)"].tap()
    // The toast lasts four seconds; check it before the slower row queries.
    toast("2 sessões arquivadas", app)
    shot("archived")
    XCTAssertTrue(rows[0].waitForNonExistence(timeout: 20))
    XCTAssertTrue(rows[1].waitForNonExistence(timeout: 20))
    XCTAssertTrue(menu.waitForNonExistence(timeout: 10), "Ao terminar, sai do modo de seleção.")
    let archive = app.buttons["sessions-archived"]
    app.revealSessionRow(archive)
    archive.tap()
    XCTAssertTrue(app.buttons["archived-row-" + ids[0]].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["archived-row-" + ids[1]].exists)
    shot("archived-list")
    app.buttons["Concluir"].tap()

    app.revealSessionRow(rows[2])
    select(rows[2], app)
    app.revealSessionRow(rows[3])
    rows[3].tap()
    menu.tap()
    app.buttons["Excluir (2)"].tap()
    let alert = app.alerts["Excluir 2 sessões"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
      format: "label CONTAINS 'não pode ser desfeito' AND label CONTAINS 'arquive em vez de excluir'")).firstMatch.exists)
    XCTAssertTrue(alert.buttons["Arquivar"].exists)
    shot("delete-confirmation")
    alert.buttons["Cancelar"].tap()
    XCTAssertTrue(rows[2].isSelected && rows[3].isSelected, "Cancelar mantém a seleção.")
    menu.tap()
    app.buttons["Excluir (2)"].tap()
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    try app.requireSandbox()
    alert.buttons["Excluir 2 sessões"].tap()
    toast("2 sessões excluídas", app)
    shot("deleted")
    XCTAssertTrue(rows[2].waitForNonExistence(timeout: 30))
    XCTAssertTrue(rows[3].waitForNonExistence(timeout: 30))
    XCTAssertTrue(menu.waitForNonExistence(timeout: 10))
  }

  private func toast(_ text: String, _ app: XCUIApplication) {
    let toast = app.descendants(matching: .any).matching(identifier: "action-toast")
      .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    XCTAssertTrue(toast.waitForExistence(timeout: 20), text)
  }

  private func select(_ row: XCUIElement, _ app: XCUIApplication) {
    app.revealSessionRow(row)
    row.press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Abrir sessão"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Selecionar"].exists)
    app.buttons["Selecionar"].tap()
    XCTAssertTrue(app.buttons["sessions-selection-menu"].waitForExistence(timeout: 5))
    XCTAssertTrue(row.isSelected)
  }
}
