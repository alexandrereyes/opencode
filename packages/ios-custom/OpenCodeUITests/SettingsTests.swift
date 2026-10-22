import XCTest

@MainActor final class SettingsTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var run: String { environment["OPENCODE_TEST_RUN_ID"] ?? "onda8" }
  private var manualName: String { "Sandbox manual · " + run }
  private var offlineName: String { "Local indisponível · " + run }
  private var pairedName: String { "Sandbox pareado · " + run }
  private var removableName: String { "Local removível · " + run }
  private func launch(child: Bool = false, override: String? = nil) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177"]
    if let override { app.launchArguments += ["-OpenCodeTheme", override] }
    if child { app.launchArguments += ["-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_CHILD"])] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launchEnvironment["OPENCODE_SETTINGS_TEST_INPUT"] = "1"
    app.launchEnvironment["OPENCODE_PAIRING_PAYLOAD"] = environment["OPENCODE_TEST_PAIRING"]
    app.launch()
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func settings(_ app: XCUIApplication) {
    app.tabBars.buttons["Você"].tap()
    for _ in 0..<3 {
      if app.navigationBars["Você"].exists { break }
      app.navigationBars.buttons.firstMatch.tap()
    }
    XCTAssertTrue(app.buttons["settings-themes"].waitForExistence(timeout: 10))
  }
  private func reveal(_ element: XCUIElement, app: XCUIApplication) {
    for _ in 0..<30 {
      let top = app.navigationBars.firstMatch.frame.maxY
      let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 60 : app.frame.maxY
      if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY < bottom { return }
      if element.exists && element.frame.minY < top { app.swipeDown(velocity: .slow) }
      else { app.swipeUp(velocity: .slow) }
    }
    XCTAssertTrue(element.exists && element.isHittable)
  }
  private func chooseTheme(_ id: String, app: XCUIApplication) {
    app.buttons["settings-themes"].tap()
    let row = app.buttons["theme-" + id]
    reveal(row, app: app)
    row.tap()
    XCTAssertTrue(row.isSelected)
    shot("themes-" + id)
    app.navigationBars.buttons.firstMatch.tap()
  }
  func testLiveThemesAndAppearancesAcrossScreens() throws {
    let app = try launch()
    XCTAssertTrue(app.tabBars.buttons["Você"].waitForExistence(timeout: 20))
    settings(app)
    chooseTheme("openchamber", app: app)
    for (family, mode, name) in [("openchamber", "Escuro", "openchamber-dark"),
                                  ("openchamber", "Claro", "openchamber-light"),
                                  ("dracula", "Escuro", "dracula-dark")] {
      if family != "openchamber" { chooseTheme(family, app: app) }
      app.segmentedControls["settings-appearance"].buttons[mode].tap()
      shot("voce-" + name)
      app.buttons["settings-themes"].tap()
      reveal(app.buttons["theme-" + family], app: app)
      shot("theme-picker-" + name)
      app.navigationBars.buttons.firstMatch.tap()
      app.buttons["settings-about"].tap()
      XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'desenvolvimento' OR value CONTAINS 'desenvolvimento'")).firstMatch.waitForExistence(timeout: 5))
      shot("about-" + name)
      app.navigationBars.buttons.firstMatch.tap()
      app.tabBars.buttons["Sessões"].tap()
      shot("sessions-" + name)
      let root = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 8 — leitura e temas'")).firstMatch
      app.revealSessionRow(root)
      root.tap()
      XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 15))
      XCTAssertTrue(app.staticTexts["Confira a aparência desta conversa."].waitForExistence(timeout: 10))
      shot("conversation-" + name)
      app.buttons["Voltar"].tap()
      settings(app)
    }
    chooseTheme("openchamber", app: app)
    app.segmentedControls["settings-appearance"].buttons["Sistema"].tap()
  }
  func testManualServersTestSwitchEditRemoveAndPairing() throws {
    let mode = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch(child: true, override: mode)
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    app.buttons["Voltar"].tap()
    settings(app)
    app.buttons["settings-servers"].tap()
    cleanPreviousTestServers(app)
    reveal(app.buttons["server-add"], app: app)
    shot("servers-initial-" + mode)
    addServer(app, name: manualName, address: "http://127.0.0.1:4177",
              password: try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"]), success: true, mode: mode)
    addServer(app, name: offlineName, address: "http://127.0.0.1:9", password: nil, success: false, mode: mode)
    selectServer(offlineName, app: app)
    XCTAssertTrue(app.staticTexts["Desconectado"].waitForExistence(timeout: 15))
    shot("server-offline-" + mode)
    app.tabBars.buttons["Sessões"].tap()
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 8 — leitura e temas'")).firstMatch.exists)
    shot("sessions-offline-clean-" + mode)
    settings(app)
    app.buttons["settings-servers"].tap()
    selectServer(manualName, app: app)
    XCTAssertTrue(app.staticTexts["Conectado"].waitForExistence(timeout: 15))
    shot("server-manual-active-" + mode)
    app.tabBars.buttons["Sessões"].tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Onda 8 — leitura e temas'")).firstMatch.waitForExistence(timeout: 20))
    settings(app)
    app.buttons["settings-servers"].tap()
    let pairing = app.buttons["server-pair"]
    reveal(pairing, app: app)
    pairing.tap()
    XCTAssertTrue(app.textViews["pairing-payload"].waitForExistence(timeout: 5))
    shot("pairing-scanner-equivalent-" + mode)
    app.buttons["pairing-test-input"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == 'Código resgatado'"),
      evaluatedWith: app.textViews["pairing-payload"])], timeout: 20), .completed)
    app.swipeUp(velocity: .slow)
    XCTAssertTrue(app.buttons["pairing-save"].waitForExistence(timeout: 5))
    shot("pairing-redeemed-" + mode)
    app.textFields["pairing-name"].tap()
    app.textFields["pairing-name"].typeText(pairedName)
    app.buttons["pairing-save"].tap()
    selectServer(pairedName, app: app)
    XCTAssertTrue(app.staticTexts["Conectado"].waitForExistence(timeout: 15))
    shot("server-paired-active-" + mode)
    // Edit and remove a non-active server, preserving the built-in entry.
    reveal(app.buttons["Editar " + offlineName], app: app)
    app.buttons["Editar " + offlineName].tap()
    let name = app.textFields["server-name"]
    name.tap()
    name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: offlineName.count) + removableName)
    app.buttons["server-test"].tap()
    XCTAssertTrue(app.staticTexts["server-test-result"].waitForExistence(timeout: 10))
    app.buttons["server-save"].tap()
    XCTAssertTrue(app.navigationBars["Editar servidor"].waitForNonExistence(timeout: 5))
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-select-' AND label CONTAINS %@", removableName)).firstMatch
    reveal(row, app: app)
    row.press(forDuration: 1)
    app.buttons["Remover"].tap()
    shot("server-remove-confirmation-" + mode)
    app.buttons["Remover servidor"].tap()
    XCTAssertFalse(row.exists)
  }
  private func cleanPreviousTestServers(_ app: XCUIApplication) {
    for _ in 0..<30 {
      let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-select-' AND (label BEGINSWITH 'Sandbox manual' OR label BEGINSWITH 'Sandbox pareado' OR label BEGINSWITH 'Local indisponível' OR label BEGINSWITH 'Local removível')")).firstMatch
      guard row.exists else { return }
      reveal(row, app: app)
      row.press(forDuration: 1)
      app.buttons["Remover"].tap()
      app.buttons["Remover servidor"].tap()
    }
  }
  private func addServer(_ app: XCUIApplication, name: String, address: String, password: String?, success: Bool, mode: String) {
    reveal(app.buttons["server-add"], app: app)
    app.buttons["server-add"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar servidor"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["server-name"].waitForExistence(timeout: 5))
    app.textFields["server-name"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.textFields["server-name"].typeText(name)
    app.textFields["server-address"].tap()
    app.textFields["server-address"].typeText(address)
    if password == nil {
      // The debug-only sandbox prefill is removed for the unreachable/no-password entry.
      app.secureTextFields["server-password"].tap()
      app.secureTextFields["server-password"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: environment["OPENCODE_TEST_PASSWORD"]?.count ?? 0))
    }
    app.buttons["server-test"].tap()
    let result = app.staticTexts["server-test-result"]
    XCTAssertTrue(result.waitForExistence(timeout: 15))
    XCTAssertTrue(result.label.contains(success ? "Conectado" : "Falha"))
    app.swipeUp(velocity: .slow)
    shot("server-add-" + (success ? "success-" : "failure-") + mode)
    app.buttons["server-save"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar servidor"].waitForNonExistence(timeout: 5))
    // iOS 27's Password AutoFill save sheet is absent from the app's AX tree.
    // Its dismiss control has a stable location on the dedicated 402×874 simulator.
    if success { app.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.64)).tap() }
    XCTAssertTrue(app.buttons["server-add"].waitForExistence(timeout: 10))
  }
  private func selectServer(_ title: String, app: XCUIApplication) {
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-select-' AND label CONTAINS %@", title)).firstMatch
    reveal(row, app: app)
    row.tap()
    XCTAssertTrue(app.buttons["settings-servers"].waitForExistence(timeout: 15))
    app.buttons["settings-servers"].tap()
  }
  func testChildPreambleHiddenAndCopyUsesAuthoredText() throws {
    let mode = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch(child: true, override: mode)
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    let prompt = app.staticTexts["Confira apenas o texto autoral do subagente."]
    XCTAssertTrue(prompt.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'You are a subagent spawned' ")).firstMatch.exists)
    shot("child-without-preamble-" + mode)
    prompt.press(forDuration: 1)
    app.buttons["Copiar"].tap()
    XCTAssertTrue(app.staticTexts["Mensagem copiada"].waitForExistence(timeout: 5))
  }
}
