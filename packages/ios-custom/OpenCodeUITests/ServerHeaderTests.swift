import XCTest

/// Sessões' server title (approved option B, 3 November) against an isolated sandbox: the current server's avatar,
/// name and connection where "Sessões" was, and its server list. `-OpenCodeFixtureServers` adds two unreachable
/// loopback servers held in memory (the sandbox is named "Mac de Alexandre"); `-OpenCodeFixtureCallActive` stands in
/// for a voice call without starting one. Run with `script/test-server-header.py`, which imports the session
/// "Rascunho entre servidores" for the draft.
@MainActor final class ServerHeaderTests: XCTestCase {
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  override func setUp() { continueAfterFailure = false }

  private func launch(_ extra: [String] = []) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme] + extra
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    try app.requireSandbox()
    XCTAssertTrue(app.buttons["sessions-server"].waitForExistence(timeout: 25))
    return app
  }
  private func shot(_ name: String) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "servidor-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func wait(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval = 25) {
    let predicate = NSPredicate(format: format, value)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout), .completed,
      "\(element.identifier): \(element.exists ? element.label : "ausente")")
  }
  /// The title stays left of voice, Nova sessão and Você, within the screen.
  private func checkHeader(_ app: XCUIApplication) {
    let title = app.buttons["sessions-server"].frame
    let voice = app.buttons["voice-start"].frame
    XCTContext.runActivity(named: "título \(title) · voz \(voice)") { _ in }
    XCTAssertGreaterThanOrEqual(title.minX, 0)
    XCTAssertLessThanOrEqual(title.maxX, voice.minX, "o título passa por baixo dos botões")
    XCTAssertLessThanOrEqual(title.height, 52, "o título ficou mais alto que os botões")
  }
  private func openServers(_ app: XCUIApplication) {
    app.buttons["sessions-server"].tap()
    XCTAssertTrue(app.navigationBars["Servidores"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["server-current"].waitForExistence(timeout: 5))
  }

  func testOneServerKeepsItsNameAndTheListOpensManageAddAndPairing() throws {
    let app = try launch()
    defer { app.terminate() }
    let title = app.buttons["sessions-server"]
    wait(title, "label == %@", "Servidor Sandbox (inicialização), conectado")
    XCTAssertFalse(app.staticTexts["sessions-title"].exists)
    checkHeader(app)
    shot("um-fechado")
    openServers(app)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-switch-'")).firstMatch.exists)
    XCTAssertFalse(app.staticTexts["Trocar para"].exists)
    shot("um-aberto")
    // Adicionar and Ler QR code are Você ▸ Servidores' own editor and reader.
    app.buttons["server-add-header"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar servidor"].waitForExistence(timeout: 10))
    app.navigationBars["Adicionar servidor"].buttons["Cancelar"].tap()
    XCTAssertTrue(app.navigationBars["Adicionar servidor"].waitForNonExistence(timeout: 10))
    app.buttons["server-pair-header"].tap()
    XCTAssertTrue(app.navigationBars["Ler QR code"].waitForExistence(timeout: 10))
    shot("um-qr")
    app.navigationBars["Ler QR code"].buttons["Fechar"].tap()
    XCTAssertTrue(app.navigationBars["Ler QR code"].waitForNonExistence(timeout: 10))
    // Gerenciar servidores opens Você on Servidores.
    app.buttons["server-manage"].tap()
    XCTAssertTrue(app.buttons["server-add"].waitForExistence(timeout: 15), "Você ▸ Servidores não abriu")
    XCTAssertTrue(app.navigationBars["Servidores"].exists)
    shot("um-gerenciar")
  }

  func testSwitchStaysInSessoesAndTheDraftComesBack() throws {
    let app = try launch(["-OpenCodeFixtureServers"])
    defer { app.terminate() }
    let title = app.buttons["sessions-server"]
    wait(title, "label == %@", "Servidor Mac de Alexandre, conectado")
    shot("varios-fechado")

    // A draft on this server, to find again after the round trip.
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rascunho entre servidores'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    // The transcript may still be settling the first tap: retry until the keyboard is up.
    for _ in 0..<4 where !app.keyboards.firstMatch.exists {
      composer.tap()
      _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
    }
    composer.typeText("Rascunho antes da troca")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(title.waitForExistence(timeout: 10))

    openServers(app)
    XCTAssertTrue(app.buttons["server-switch-escritorio"].exists && app.buttons["server-switch-ci"].exists)
    XCTAssertTrue(app.staticTexts["127.0.0.1:4243"].exists, "o endereço do outro servidor")
    shot("varios-aberto")
    app.buttons["server-switch-escritorio"].tap()
    // Stays in Sessões, on the other server; its long name is cut and keeps clear of the buttons.
    wait(title, "label BEGINSWITH %@", "Servidor Mac mini do escritório — clientes, ")
    wait(app.staticTexts["debug-server-url"], "label == %@", "http://127.0.0.1:4243")
    XCTAssertFalse(app.navigationBars["Você"].exists, "a troca reabriu Você")
    checkHeader(app)
    wait(title, "label ENDSWITH %@", ", desconectado", timeout: 40)
    shot("nome-longo-desconectado")

    openServers(app)
    app.buttons["server-switch-builtin"].tap()
    wait(app.staticTexts["debug-server-url"], "label == %@", TestSandbox.url)
    wait(title, "label == %@", "Servidor Mac de Alexandre, conectado")
    XCTAssertFalse(app.navigationBars["Você"].exists, "a troca reabriu Você")
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    wait(composer, "value == %@", "Rascunho antes da troca")
  }

  func testVoiceCallAsksBeforeSwitching() throws {
    let app = try launch(["-OpenCodeFixtureServers", "-OpenCodeFixtureCallActive"])
    defer { app.terminate() }
    let title = app.buttons["sessions-server"]
    wait(title, "label == %@", "Servidor Mac de Alexandre, conectado")
    openServers(app)
    app.buttons["server-switch-ci"].tap()
    let alert = app.alerts["Trocar para Servidor Linux de CI?"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    shot("voz-confirmacao")
    // Cancelar keeps the call and the server.
    alert.buttons["Cancelar"].tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["Servidores"].exists)
    XCTAssertEqual(app.staticTexts["debug-server-url"].label, TestSandbox.url)
    app.buttons["server-switch-ci"].tap()
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    alert.buttons["Trocar"].tap()
    wait(app.staticTexts["debug-server-url"], "label == %@", "http://127.0.0.1:4244")
    wait(title, "label BEGINSWITH %@", "Servidor Servidor Linux de CI, ")
    XCTAssertFalse(app.navigationBars["Você"].exists, "a troca reabriu Você")
  }

  func testLargeTextKeepsTheTitleOnItsOwnLine() throws {
    let app = try launch(["-OpenCodeFixtureServers", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL"])
    defer { app.terminate() }
    let title = app.buttons["sessions-server"]
    wait(title, "label == %@", "Servidor Mac de Alexandre, conectado")
    XCTAssertLessThanOrEqual(title.frame.maxX, app.windows.firstMatch.frame.maxX)
    shot("texto-grande")
    openServers(app)
    shot("texto-grande-aberto")
  }
}
