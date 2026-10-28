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
    // Fail before any interaction if launch ever falls through to AppRoot/a real connection.
    XCTAssertTrue(app.buttons["session-row-ses_scroll_0000"].waitForExistence(timeout: 10), "Catálogo offline não carregou")
    XCTAssertEqual(app.staticTexts["debug-server-url"].label, "http://127.0.0.1:4183")
    XCTAssertFalse(app.tabBars.firstMatch.exists)
    // Complete both inline icon decodes, including SVG rasterization, before capturing any screen.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
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
    let app = launch(["-OpenCodeCatalogSections"])
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["session-section-attention"].waitForExistence(timeout: 10))
    shot("sessions-list-all")
    chip("filter-chats", app)
    shot("sessions-list-chats")
    chip("filter-project-Projeto Exemplo 0", app)
    shot("sessions-list-repository")
    // No tab bar: Você opens from the header avatar.
    app.openYou()
    shot("you-settings-default")
  }

  /// Every section of the column: the top of the list, then the days with "Anteriores" expanded.
  func testSections() {
    let app = launch(["-OpenCodeCatalogSections"])
    defer { app.terminate() }
    let headers = ["attention", "running", "pinned", "today", "yesterday", "week", "older"]
      .map { app.buttons["session-section-" + $0] }
    XCTAssertTrue(headers[0].waitForExistence(timeout: 10))
    XCTAssertEqual(headers[0].label, "Precisa de você, 3")
    XCTAssertTrue(app.buttons["session-row-ses_scroll_0005"].label.contains("erro · bun test falhou · há 12 min"))
    XCTAssertTrue(app.buttons["Permitir"].exists && app.buttons["Negar"].exists)
    XCTAssertFalse(app.buttons["Responder"].exists)
    let list = app.collectionViews.firstMatch
    // Short drags, so no section header scrolls past unseen.
    let drag = {
      let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
      start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)),
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    for header in headers.dropFirst() {
      for _ in 0..<8 where !(header.exists && header.isHittable) { drag() }
      XCTAssertTrue(header.isHittable, header.identifier)
    }
    XCTAssertEqual(headers[6].value as? String, "recolhida")
    XCTAssertFalse(app.buttons["session-row-ses_scroll_0010"].exists)
    headers[6].tap()
    XCTAssertTrue(app.buttons["session-row-ses_scroll_0010"].waitForExistence(timeout: 5))
    let archived = app.buttons["sessions-archived"]
    // The master accessory covers the last row while AX still reports it hittable.
    for _ in 0..<3 where !archived.exists || archived.frame.maxY > app.buttons["master-accessory"].frame.minY { drag() }
    XCTAssertTrue(archived.label.hasPrefix("Arquivadas"))
    shot("sessions-sections-history")
    headers[6].tap()
    XCTAssertEqual(headers[6].value as? String, "recolhida")
  }

  /// The Mac's variant of the shared header: Configurações between voice and Nova sessão.
  func testSettingsHeader() {
    let plain = launch()
    XCTAssertFalse(plain.buttons["sessions-settings"].exists)
    XCTAssertFalse(plain.buttons["Mais opções"].exists)
    plain.terminate()
    let app = launch(["-OpenCodeCatalogSettingsButton"])
    defer { app.terminate() }
    let settings = app.buttons["sessions-settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    XCTAssertEqual(settings.label, "Configurações")
    let voice = app.buttons["voice-start"].frame
    let add = app.buttons["Nova sessão"].frame
    XCTAssertTrue(voice.maxX <= settings.frame.minX && settings.frame.maxX <= add.minX)
    XCTAssertEqual(app.sessionsTitle.frame.midY, settings.frame.midY, accuracy: 12)
    shot("sessions-header-settings")
    settings.tap()
    XCTAssertTrue(app.navigationBars["Você"].waitForExistence(timeout: 10))
  }

  func testUnreadChips() {
    let app = launch(["-OpenCodeCatalogUnread", "-OpenCodeCatalogNoRunning"])
    defer { app.terminate() }
    let unread = app.buttons["filter-project-Projeto Exemplo 3"]
    let chats = app.buttons["filter-chats"]
    XCTAssertTrue(unread.waitForExistence(timeout: 10))
    XCTAssertEqual(unread.label, "Projeto Exemplo 3, com não lidas")
    XCTAssertLessThan(unread.frame.minX, chats.frame.minX)
    shot("sessions-chips-unread")
  }

  func testMixedChats() {
    let app = launch()
    defer { app.terminate() }
    let chat = app.buttons["session-row-ses_scroll_0001"]
    XCTAssertTrue(chat.waitForExistence(timeout: 10))
    XCTAssertTrue(chat.label.contains("Chats"))
    shot("sessions-chats-mixed")
  }

  func testRunningChips() {
    let app = launch(["-OpenCodeCatalogUnread"])
    defer { app.terminate() }
    let running = app.buttons["filter-project-Projeto Exemplo 0"]
    let unread = app.buttons["filter-project-Projeto Exemplo 3"]
    XCTAssertTrue(running.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(running.frame.minX, app.buttons["filter-all"].frame.minX)
    XCTAssertLessThan(running.frame.minX, unread.frame.minX)
    XCTAssertLessThan(unread.frame.minX, app.buttons["filter-chats"].frame.minX)
    shot("sessions-chips-running")
  }

  func testChatsOrderMenu() {
    let app = launch(["-OpenCodeCatalogNoRunning"])
    defer { app.terminate() }
    chip("filter-chats", app)
    app.buttons["filter-chats"].press(forDuration: 1)
    XCTAssertTrue(app.buttons["Mover para depois"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Mover para antes"].exists)
    shot("sessions-chats-order-menu")
  }

  func testSessionSelection() {
    let app = launch()
    defer { app.terminate() }
    let row = app.buttons["session-row-ses_scroll_0000"]
    row.press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Selecionar"].waitForExistence(timeout: 5))
    if theme == "dark" { shot("sessions-select-context-menu") }
    tap("Selecionar", app)
    XCTAssertEqual(app.staticTexts["sessions-selection-count"].label, "1 selecionada")
    shot("sessions-select-mode")
    if theme == "light" { return }
    tap("sessions-selection-menu", app)
    XCTAssertTrue(app.buttons["Arquivar (1)"].waitForExistence(timeout: 5))
    shot("sessions-select-actions")
    tap("Excluir (1)", app)
    let confirmation = app.alerts["Excluir 1 sessão"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    shot("sessions-select-delete-confirmation")
    confirmation.buttons["Cancelar"].tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    tap("sessions-selection-done", app)
  }

  func testNotifySwipe() {
    let app = launch()
    defer { app.terminate() }
    let row = app.buttons["session-row-ses_scroll_0000"]
    XCTAssertTrue(row.label.contains("avisa ao terminar"))
    shot("sessions-notify-enabled")
    let other = app.buttons["session-row-ses_scroll_0002"]
    app.revealSessionRow(other)
    other.swipeLeft()
    XCTAssertTrue(app.buttons["Avisar ao terminar"].waitForExistence(timeout: 5))
    shot("sessions-swipe-notify")
    // Never toggle the preference; this reference only shows the available action.
  }

  func testSessionSwitcher() {
    let app = launch()
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    tap("conversation-switcher", app)
    let current = app.buttons["switcher-row-ses_scroll_0000"]
    XCTAssertTrue(current.waitForExistence(timeout: 10))
    XCTAssertTrue(current.isSelected)
    app.navigationBars["Sessões"].swipeUp()
    XCTAssertTrue(app.buttons["switcher-row-ses_scroll_0001"].waitForExistence(timeout: 10))
    shot("session-switcher-open")
    let search = app.searchFields["Buscar sessão"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("contraste")
    XCTAssertTrue(app.buttons["switcher-row-ses_scroll_0008"].waitForExistence(timeout: 10))
    shot("session-switcher-search")
  }

  func testSettings() {
    let app = launch()
    defer { app.terminate() }
    app.openYou()
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

  func testNewSessionFromRepository() {
    let app = launch()
    defer { app.terminate() }
    chip("filter-project-Projeto Exemplo 0", app)
    tap("Nova sessão", app)
    XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["new-project"].label.contains("Projeto Exemplo 0"))
    shot("new-session-from-repository-chip")
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
    tap("Mais opções", app)
    tap("Detalhes da sessão", app)
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
    XCTAssertTrue(app.buttons["Agentes (3)"].waitForExistence(timeout: 10))
    let running = app.buttons["agent-work-ses_catalog_review"]
    let finished = app.buttons["agent-work-ses_catalog_finished"]
    XCTAssertLessThan(running.frame.minY, finished.frame.minY)
    XCTAssertFalse(app.staticTexts["Sem recursos"].exists)
    shot("session-agents-resources")
    app.swipeUp()
    shot("session-agents-finished")
    tap("Scripts (1)", app)
    XCTAssertTrue(app.buttons["agent-work-catalog-script"].waitForExistence(timeout: 10))
    shot("session-agents-scripts")
    tap("Agentes (3)", app)
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
    tap("Fechar", app)
    tap("file-explorer-file-index.html", app)
    XCTAssertTrue(app.webViews.firstMatch.staticTexts["Próxima versão"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.descendants(matching: .any)["file-html-mode"].exists)
    shot("files-html-preview")
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
    app.openYou()
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
    app.buttons["Voltar"].tap()
    if !app.sessionsTitle.waitForExistence(timeout: 10) { print(app.debugDescription) }
    XCTAssertTrue(app.sessionsTitle.exists)
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

  /// A running conversation: the activity card open on its timeline (Ler, Shell, Agente, Editar), the tray
  /// with the execution and two queued messages, and the empty composer with its placeholder.
  func testActivity() {
    let app = launch(["-OpenCodeCatalogActivity"])
    defer { app.terminate() }
    tap("session-row-ses_scroll_0000", app)
    let transcript = app.collectionViews["conversation-transcript"]
    let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-context:'")).firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    // The pinned prompt covers the card's top at large text sizes; move until the card is clear of it.
    let pinned = app.descendants(matching: .any)["conversation-pinned-user"].firstMatch
    let tray = app.staticTexts["tray-running"]
    let clear = {
      group.exists && group.isHittable && (!pinned.exists || group.frame.minY >= pinned.frame.maxY)
        && (!tray.exists || group.frame.maxY <= tray.frame.minY - 16)
    }
    // Short drags in the gutter, so the card never jumps past the gap between the prompt and the tray.
    let drag = { (distance: CGFloat) in
      let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.6))
      start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
        withVelocity: .slow, thenHoldForDuration: 0.3)
    }
    for _ in 0..<12 where !clear() {
      drag(group.exists && group.frame.minY < (pinned.exists ? pinned.frame.maxY : app.frame.midY) ? 90 : -90)
    }
    XCTAssertTrue(group.waitForExistence(timeout: 10))
    XCTAssertTrue(group.label.hasPrefix("Atividade · Ler, Shell, Agente e Editar · 4 ferramentas · "), group.label)
    XCTAssertEqual(group.value as? String, "Recolhido")
    // Its leading edge: Ir para a mais recente may float over the trailing end.
    group.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
    XCTAssertEqual(group.value as? String, "Expandido")
    XCTAssertTrue(app.buttons["activity-file-activity:file:call_catalog_3:/Projetos/exemplo-0/Sources/ChatView.swift"].exists)
    XCTAssertTrue(app.staticTexts["tray-running"].label.hasPrefix("Modelo Exemplo · trabalhando · "))
    for id in ["msg_catalog_queued_1", "msg_catalog_queued_2"] {
      XCTAssertTrue(app.descendants(matching: .any)["tray-queued-" + id].exists, id)
    }
    XCTAssertEqual(app.buttons.matching(identifier: "Enviar agora").count, 2)
    XCTAssertTrue(app.buttons["Parar"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["pending-user-msg_catalog_queued_1"].exists)
    // Evidence at accessibility text sizes (not part of the catalog): the open card where it was tapped.
    if ProcessInfo.processInfo.environment["OPENCODE_CATALOG_ACCESSIBILITY"] != nil {
      drag(-120)
      shot("activity-accessibility")
    }
    for _ in 0..<2 { transcript.swipeUp() }
    shot("conversation-activity-open")
  }

  /// The Mac's chat header, built from the avatar and title the iPhone header also uses.
  func testConversationTitleBar() {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4183", "-OpenCodeTheme", "openchamber-" + theme,
      "-OpenCodeConversationTitleFixture"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["conversation-header-title"].waitForExistence(timeout: 20))
    XCTAssertEqual(app.staticTexts["conversation-header-subtitle"].label, "opencode2-mac-app-mocks · trabalhando…")
    XCTAssertTrue(app.buttons["conversation-title-bar-new"].exists)
    shot("conversation-title-bar-mac")
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
