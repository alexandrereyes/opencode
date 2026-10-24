import XCTest

@MainActor extension XCUIApplication {
  /// The rename alert opens focused with the whole title selected, so one keystroke replaces it.
  func assertRenameTitleSelected() {
    let field = alerts["Renomear sessão"].textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertTrue(keyboards.firstMatch.waitForExistence(timeout: 5), "O teclado deve abrir com a janela.")
    let old = field.value as? String ?? ""
    XCTAssertFalse(old.isEmpty || old == "X")
    // Typing into the app, not the field: tapping the field would collapse the selection.
    typeText("X")
    XCTAssertEqual(field.value as? String, "X", "O título atual deve vir todo selecionado.")
  }
}
