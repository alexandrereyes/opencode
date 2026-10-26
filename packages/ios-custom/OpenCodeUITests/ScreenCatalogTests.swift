import XCTest

/// Reference images, not a replacement for the behavior suites. Every launch is server-free.
@MainActor final class ScreenCatalogTests: XCTestCase {
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_CATALOG_THEME"] ?? "dark" }
  override func setUp() { continueAfterFailure = false }

  private func launch(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4183", "-OpenCodeTheme", "openchamber-" + theme,
      "-OpenCodeScrollFixture", "catalog", "-OpenCodeFixturePosition", "top",
      "-OpenCodeCollapsibleUserMessages", "YES"] + extra
    app.launchEnvironment["OPENCODE_PROXY_STUB"] = "success"
    app.launch()
    XCTAssertTrue(app.buttons["Nova sessão"].waitForExistence(timeout: 20))
    return app
  }

  private func shot(_ name: String) {
    // A fresh simulator may cover its first keyboard with Apple's QuickPath introduction.
    let introduction = XCUIApplication().buttons.matching(
      NSPredicate(format: "label == 'Continue' OR label == 'Continuar'")).firstMatch
    if introduction.exists {
      introduction.tap()
      XCTAssertTrue(introduction.waitForNonExistence(timeout: 5))
    }
    // Let native sheet and keyboard transitions finish before asking the compositor for pixels.
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name + "-" + theme
    image.lifetime = .keepAlways
    add(image)
  }

  private func tap(_ id: String, _ app: XCUIApplication) {
    let element = app.descendants(matching: .any)[id].firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 10), id)
    element.tap()
  }

  private func chip(_ id: String, _ app: XCUIApplication) {
    let element = app.buttons[id]
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    let strip = app.scrollViews.containing(.button, identifier: "filter-chats").firstMatch
    for _ in 0..<5 {
      if element.isHittable && element.frame.minX >= 0 && element.frame.maxX <= app.frame.width { break }
      if element.frame.minX < 0 { strip.swipeRight() }
      else { strip.swipeLeft() }
    }
    element.tap()
  }

  func testTabs() {
    let app = launch()
    defer { app.terminate() }
    shot("sessions-list-all")
    chip("filter-chats", app)
    shot("sessions-list-chats")
    chip("filter-project-Projeto Exemplo 0", app)
    shot("sessions-list-repository")
    for (title, name) in [("Painel", "dashboard-tab-default"), ("Pedidos", "requests-tab-default"),
                           ("Projetos", "projects-tab-default"), ("Você", "you-settings-default")] {
      app.tabBars.buttons[title].tap()
      shot(name)
    }
  }

  func testUnreadChips() {
    let app = launch(["-OpenCodeCatalogUnread"])
    defer { app.terminate() }
    let unread = app.buttons["filter-project-Projeto Exemplo 3"]
    let chats = app.buttons["filter-chats"]
    XCTAssertTrue(unread.waitForExistence(timeout: 10))
    XCTAssertEqual(unread.label, "Projeto Exemplo 3, com não lidas")
    XCTAssertLessThan(unread.frame.minX, chats.frame.minX)
    shot("sessions-chips-unread")
  }

  func testSettings() {
    let app = launch()
    defer { app.terminate() }
    app.tabBars.buttons["Você"].tap()
    tap("settings-themes", app)
    shot("you-themes-default")
    app.navigationBars.buttons.firstMatch.tap()
    for _ in 0..<3 {
      if app.buttons["settings-device-data"].isHittable { break }
      app.swipeUp()
    }
    tap("settings-device-data", app)
    shot("you-iphone-data-default")
  }

  func testNewSession() {
    let app = launch()
    defer { app.terminate() }
    tap("Nova sessão", app)
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 10))
    shot("new-session-chats-empty")
    tap("new-project", app)
    shot("new-session-project-sheet")
    tap("new-project-Projeto Exemplo 0", app)
    shot("new-session-project-empty")
    tap("new-directory", app)
    shot("new-session-directory-sheet")
  }

  func testConversation() {
    let app = launch()
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    shot("conversation-user-collapsed")
    let toggle = app.buttons["user-prompt-toggle-msg_catalog_user"]
    if toggle.waitForExistence(timeout: 5) {
      toggle.tap()
      shot("conversation-user-expanded")
      toggle.tap()
    }
    app.collectionViews["conversation-transcript"].swipeUp()
    shot("conversation-answer-footer")
    tap("conversation-usage", app)
    shot("session-details-default")
    tap("Fechar", app)
    tap("model-picker", app)
    shot("conversation-model-picker")
    tap("Concluir", app)
    tap("Adicionar", app)
    shot("conversation-add-menu")
  }

  func testConversationSelectors() {
    let app = launch()
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    tap("agent-picker", app)
    shot("conversation-agent-picker")
    tap("Concluir", app)
    tap("conversation-mcp-pill", app)
    shot("conversation-mcp-picker")
  }

  func testFilesAndResources() {
    let app = launch()
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    tap("conversation-agents", app)
    XCTAssertTrue(app.buttons["Agentes (1)"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Sem recursos"].exists)
    shot("session-agents-resources")
    tap("Scripts (1)", app)
    XCTAssertTrue(app.buttons["agent-work-catalog-script"].waitForExistence(timeout: 10))
    shot("session-agents-scripts")
    tap("Agentes (1)", app)
    app.navigationBars.buttons.firstMatch.tap()
    tap("conversation-usage", app)
    let directory = app.buttons["session-details-directory"]
    for _ in 0..<5 where !directory.isHittable { app.swipeUp() }
    directory.tap()
    XCTAssertTrue(app.buttons["file-explorer-file-README.md"].waitForExistence(timeout: 10))
    shot("files-explorer-default")
    tap("file-explorer-file-README.md", app)
    XCTAssertTrue(app.buttons["file-markdown-source"].waitForExistence(timeout: 10))
    shot("files-markdown-default")
    tap("Fechar", app)
    tap("file-explorer-file-preview.png", app)
    XCTAssertTrue(app.navigationBars["preview.png"].waitForExistence(timeout: 10))
    shot("files-image-default")
  }

  func testScriptsEmpty() {
    let app = launch(["-OpenCodeCatalogNoScripts"])
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    tap("conversation-agents", app)
    tap("Scripts (0)", app)
    XCTAssertTrue(app.descendants(matching: .any)["scripts-empty"].waitForExistence(timeout: 10))
    shot("session-agents-scripts-empty")
  }

  func testAddRepository() {
    let app = launch()
    defer { app.terminate() }
    tap("Nova sessão", app)
    tap("new-project", app)
    tap("Adicionar projeto", app)
    XCTAssertTrue(app.navigationBars["Adicionar repositório"].waitForExistence(timeout: 10))
    shot("projects-add-repository")
  }

  func testSubscriptions() {
    let app = launch()
    defer { app.terminate() }
    app.tabBars.buttons["Você"].tap()
    tap("proxy-settings-codex", app)
    XCTAssertTrue(app.otherElements["proxy-pool-header"].waitForExistence(timeout: 10))
    shot("you-subscriptions-default")
  }

  func testMasterAndVoice() {
    let app = launch(["-OpenCodeVoiceBarFixture", "speaking"])
    defer { app.terminate() }
    shot("sessions-voice-speaking")
    tap("master-accessory", app)
    XCTAssertTrue(app.staticTexts["master-empty"].waitForExistence(timeout: 10))
    shot("master-session-empty")
  }

  func testPending() {
    let app = launch(["-OpenCodeCatalogPending"])
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    let pending = app.descendants(matching: .any)["pending-user-msg_catalog_pending"]
    for _ in 0..<4 where !pending.exists { app.collectionViews["conversation-transcript"].swipeUp() }
    XCTAssertTrue(pending.waitForExistence(timeout: 10))
    shot("conversation-user-pending")
  }

  func testShortPrompt() {
    let app = launch(["-OpenCodeCatalogShort"])
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    XCTAssertTrue(app.staticTexts["Como podemos simplificar a navegação?"].waitForExistence(timeout: 10))
    shot("conversation-user-normal")
  }

  func testQuote() {
    let app = launch(["-OpenCodeCatalogQuote"])
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    tap("draft-quotes", app)
    shot("conversation-quote-draft")
    tap("Editar citação", app)
    XCTAssertTrue(app.textViews["comment-composer"].waitForExistence(timeout: 10))
    shot("conversation-quote-comment")
    tap("Cancelar", app)
    tap("Ir ao trecho citado", app)
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    marker.tap()
    XCTAssertTrue(app.navigationBars["Citação · 1"].waitForExistence(timeout: 10))
    shot("conversation-quote-details")
  }

  func testSideQuestion() {
    let app = launch(["-OpenCodeSideQuestionFixture", "-OpenCodeCatalogSideQuestion"])
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    XCTAssertTrue(app.textViews["side-question-composer"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.scrollViews["side-question-scroll"].buttons["Copiar resposta"].waitForExistence(timeout: 10))
    shot("conversation-side-question")
  }

  func testZComposer() {
    let app = launch()
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText("Vamos começar pelos filtros de projetos.")
    shot("conversation-composer-text")
  }
}
