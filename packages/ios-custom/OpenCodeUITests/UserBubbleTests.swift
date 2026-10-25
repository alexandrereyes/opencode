import XCTest
import UIKit

@MainActor final class UserBubbleTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }

  private func launch(_ role: String = "BUBBLE", theme: String? = nil, preference: Bool? = true) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme ?? environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_" + role]),
    ]
    if let preference { app.launchArguments += ["-OpenCodeCollapsibleUserMessages", preference ? "YES" : "NO"] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 20), .completed)
  }
  private func prompt(_ app: XCUIApplication) throws -> XCUIElement {
    app.descendants(matching: .any)["user-prompt-" + (try XCTUnwrap(environment["OPENCODE_TEST_BUBBLE_MESSAGE"]))]
  }
  private func toggle(_ app: XCUIApplication) throws -> XCUIElement {
    app.buttons["user-prompt-toggle-" + (try XCTUnwrap(environment["OPENCODE_TEST_BUBBLE_MESSAGE"]))]
  }
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func scrollAnswer(_ app: XCUIApplication, below: CGFloat, up: Bool) {
    let list = app.collectionViews["conversation-transcript"].frame
    let top = max(below + 24, list.midY)
    let bottom = list.maxY - 24
    let a = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.midX, dy: up ? bottom : top))
    let b = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.midX, dy: up ? top : bottom))
    a.press(forDuration: 0.05, thenDragTo: b)
  }

  func testPinnedPromptOnlyChangesWhenExplicitlyExpandedInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch(theme: theme)
      let control = try toggle(app)
      let text = try prompt(app)
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      // A saved reading anchor can open with the prompt still in its natural
      // position. Cross the sticky edge before comparing pinned coordinates.
      scrollAnswer(app, below: control.frame.maxY, up: true)
      XCTAssertEqual(control.value as? String, "Recolhido")
      let height = text.frame.height
      let y = text.frame.minY
      let twoLines = UIFontMetrics(forTextStyle: .body).scaledValue(for: 22.5) * 2
      XCTAssertEqual(height, ceil(twoLines), accuracy: 1)
      shot(app, "app-collapsed-" + theme)
      for up in [false, true, false] {
        scrollAnswer(app, below: control.frame.maxY, up: up)
        XCTAssertEqual(control.value as? String, "Recolhido")
        XCTAssertEqual(text.frame.height, height, accuracy: 1)
        XCTAssertEqual(text.frame.minY, y, accuracy: 2)
      }
      text.tap()
      wait(NSPredicate(format: "value == 'Expandido'"), on: control)
      XCTAssertGreaterThan(text.frame.height, height)
      XCTAssertLessThanOrEqual(text.frame.height, app.frame.height * 0.4)
      let expandedHeight = text.frame.height
      shot(app, "app-expanded-" + theme)
      for up in [true, false] {
        scrollAnswer(app, below: control.frame.maxY, up: up)
        XCTAssertEqual(control.value as? String, "Expandido")
        XCTAssertEqual(text.frame.height, expandedHeight, accuracy: 1)
      }
      text.tap()
      XCTAssertEqual(control.value as? String, "Expandido", "Tocar o texto expandido não recolhe")
      text.swipeUp(velocity: .slow)
      shot(app, "app-internal-scroll-" + theme)
      XCTAssertEqual(control.value as? String, "Expandido")
      control.tap()
      wait(NSPredicate(format: "value == 'Recolhido'"), on: control)
      XCTAssertEqual(text.frame.height, height, accuracy: 1)
      control.tap()
      wait(NSPredicate(format: "value == 'Expandido'"), on: control)
      control.tap()
      shot(app, "app-recollapsed-" + theme)
      app.terminate()
    }
  }

  func testShortPromptHasNoExpansionControl() throws {
    let app = try launch("SHORT")
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'user-prompt-toggle-'")).firstMatch.exists)
    app.terminate()
  }

  func testTruncatedPromptHidesImagesUntilExpandedInBothThemes() throws {
    let image = "feed-image-captura-sintetica-com-nome-muito-longo.png"
    let anyImage = NSPredicate(format: "identifier BEGINSWITH 'feed-image-'")
    for theme in ["openchamber-dark", "openchamber-light"] {
      var app = try launch("IMAGE_LONG", theme: theme)
      let control = app.buttons["user-prompt-toggle-" + (try XCTUnwrap(environment["OPENCODE_TEST_IMAGE_LONG_MESSAGE"]))]
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      XCTAssertEqual(control.value as? String, "Recolhido")
      XCTAssertFalse(app.buttons.matching(anyImage).firstMatch.exists)
      shot(app, "app-image-collapsed-" + theme)
      control.tap()
      wait(NSPredicate(format: "value == 'Expandido'"), on: control)
      XCTAssertTrue(app.buttons[image].waitForExistence(timeout: 10))
      shot(app, "app-image-expanded-" + theme)
      control.tap()
      wait(NSPredicate(format: "value == 'Recolhido'"), on: control)
      XCTAssertFalse(app.buttons.matching(anyImage).firstMatch.exists)
      app.terminate()
      app = try launch("IMAGE_SHORT", theme: theme)
      XCTAssertTrue(app.buttons[image].waitForExistence(timeout: 10))
      XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'user-prompt-toggle-'")).firstMatch.exists)
      shot(app, "app-image-short-" + theme)
      app.terminate()
    }
  }

  func testQuotesStayFoldedUntilExpandedInBothThemes() throws {
    let anyContext = NSPredicate(format: "identifier BEGINSWITH 'user-context-'")
    for theme in ["openchamber-dark", "openchamber-light"] {
      for role in ["QUOTES_LONG", "QUOTE_SHORT"] {
        let id = try XCTUnwrap(environment["OPENCODE_TEST_" + role + "_MESSAGE"])
        var app = try launch(role, theme: theme)
        let control = app.buttons["user-prompt-toggle-" + id]
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        XCTAssertEqual(control.value as? String, "Recolhido")
        XCTAssertEqual(control.label, "Mostrar mensagem completa")
        XCTAssertFalse(app.descendants(matching: .any).matching(anyContext).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Comentário 1 preservado."].exists)
        shot(app, "app-quotes-collapsed-" + role.lowercased() + "-" + theme)
        control.tap()
        wait(NSPredicate(format: "value == 'Expandido'"), on: control)
        let count = role == "QUOTES_LONG" ? 3 : 1
        for index in 0..<count {
          XCTAssertTrue(app.buttons["user-context-quote-\(id)-quote-\(index)"].waitForExistence(timeout: 5))
          XCTAssertTrue(app.staticTexts["Comentário \(index + 1) preservado."].exists)
        }
        shot(app, "app-quotes-expanded-" + role.lowercased() + "-" + theme)
        control.tap()
        wait(NSPredicate(format: "value == 'Recolhido'"), on: control)
        XCTAssertFalse(app.descendants(matching: .any).matching(anyContext).firstMatch.exists)
        app.terminate()
        app = try launch(role, theme: theme, preference: false)
        XCTAssertTrue(app.buttons["user-context-quote-\(id)-quote-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["user-prompt-toggle-" + id].exists)
        shot(app, "app-quotes-disabled-" + role.lowercased() + "-" + theme)
        app.terminate()
      }
      let id = try XCTUnwrap(environment["OPENCODE_TEST_QUOTE_ONLY_MESSAGE"])
      let app = try launch("QUOTE_ONLY", theme: theme)
      let control = app.buttons["user-prompt-toggle-" + id]
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      XCTAssertTrue(app.buttons["user-context-summary-\(id)-quote-0"].exists)
      shot(app, "app-quote-only-collapsed-" + theme)
      control.tap()
      XCTAssertTrue(app.buttons["user-context-quote-\(id)-quote-0"].waitForExistence(timeout: 5))
      app.terminate()
    }
  }

  func testPromptTextIsAccessibleSeparatelyFromExpansionInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch(theme: theme)
      let control = try toggle(app)
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      let text = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pedido longo de comparação.'")).firstMatch
      let collapsedTree = XCTAttachment(string: app.debugDescription)
      collapsedTree.name = "user-prompt-accessibility-collapsed-" + theme
      collapsedTree.lifetime = .keepAlways
      add(collapsedTree)
      XCTAssertTrue(text.waitForExistence(timeout: 5))
      XCTAssertTrue(text.label.contains("Detalhe final exclusivo."))
      XCTAssertFalse(text.label.contains("Mostrar mensagem completa"))
      XCTAssertEqual(control.label, "Mostrar mensagem completa")
      scrollAnswer(app, below: control.frame.maxY, up: false)
      XCTAssertTrue(text.exists)
      XCTAssertEqual(control.value as? String, "Recolhido")
      control.tap()
      wait(NSPredicate(format: "value == 'Expandido'"), on: control)
      XCTAssertTrue(text.exists)
      XCTAssertTrue(text.label.contains("Detalhe final exclusivo."))
      XCTAssertFalse(text.label.contains("Mostrar menos"))
      let expandedTree = XCTAttachment(string: app.debugDescription)
      expandedTree.name = "user-prompt-accessibility-expanded-" + theme
      expandedTree.lifetime = .keepAlways
      add(expandedTree)
      control.tap()
      wait(NSPredicate(format: "value == 'Recolhido'"), on: control)
      XCTAssertTrue(text.exists)
      app.terminate()
    }
  }

  func testCopyAndQuoteMenuPreserveCollapsedState() throws {
    let app = try launch()
    let text = try prompt(app)
    text.press(forDuration: 1)
    XCTAssertTrue(app.buttons["Copiar"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Copiar citação"].exists)
    app.buttons["Copiar"].tap()
    XCTAssertEqual(try toggle(app).value as? String, "Recolhido")
    XCTAssertTrue(app.staticTexts["nota-sintetica.txt"].exists)
    shot(app, "app-copy-menu-preserved")
    app.terminate()
  }

  func testCopyButtonCopiesFullCollapsedPromptWithoutToastInBothThemes() throws {
    let id = try XCTUnwrap(environment["OPENCODE_TEST_BUBBLE_MESSAGE"])
    let expected = try XCTUnwrap(environment["OPENCODE_TEST_BUBBLE_TEXT"])
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch(theme: theme)
      let copy = app.buttons["user-copy-" + id].firstMatch
      let revert = app.buttons["user-revert-" + id].firstMatch
      let time = app.staticTexts["user-time-" + id].firstMatch
      XCTAssertTrue(copy.waitForExistence(timeout: 10))
      XCTAssertEqual(copy.label, "Copiar mensagem")
      XCTAssertEqual(try toggle(app).value as? String, "Recolhido")
      // The button frame is its 48 × 44 pt hit target; the glyphs keep the ↶ spacing.
      XCTAssertLessThan(revert.frame.midX, copy.frame.midX)
      XCTAssertLessThan(copy.frame.midX, time.frame.minX)
      XCTAssertEqual(copy.frame.midX - revert.frame.midX, 36, accuracy: 1)
      XCTAssertGreaterThanOrEqual(copy.frame.height, 43.5)
      XCTAssertGreaterThanOrEqual(copy.frame.width, 43.5)
      // 12 pt above (gap and empty bubble padding) and 8 pt below (the host's bottom padding).
      XCTAssertEqual(copy.frame.minY, revert.frame.minY - 12, accuracy: 1)
      XCTAssertEqual(copy.frame.maxY, revert.frame.maxY + 8, accuracy: 1)
      shot(app, "app-copy-button-" + theme)
      // Below the 24 pt glyph frame, inside the 44 pt target.
      copy.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 18)).tap()
      wait(NSPredicate(format: "value == 'Copiada'"), on: copy)
      shot(app, "app-copy-checked-" + theme)
      XCTAssertFalse(app.descendants(matching: .any)["action-toast"].exists)
      XCTAssertEqual(try toggle(app).value as? String, "Recolhido")
      wait(NSPredicate(format: "value != 'Copiada'"), on: copy)
      // Paste inside the app: reading the pasteboard from the runner could raise a paste prompt.
      let composer = app.textViews["conversation-composer"]
      composer.tap()
      composer.press(forDuration: 1.2)
      let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Colar', 'Paste'}")).firstMatch
      XCTAssertTrue(paste.waitForExistence(timeout: 5))
      paste.tap()
      wait(NSPredicate(format: "value == %@", expected), on: composer)
      composer.press(forDuration: 1.2)
      let all = app.descendants(matching: .any).matching(NSPredicate(format: "label IN {'Selecionar Tudo', 'Select All'}")).firstMatch
      XCTAssertTrue(all.waitForExistence(timeout: 5))
      all.tap()
      composer.typeText(XCUIKeyboardKey.delete.rawValue)
      wait(NSPredicate(format: "value != %@", expected), on: composer)
      app.terminate()
    }
  }

  func testCollapsePreferenceInVoceDefaultsOnAndPersists() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      var app = try launch(theme: theme, preference: nil)
      XCTAssertTrue(try toggle(app).waitForExistence(timeout: 10))
      app.buttons["Voltar"].tap()
      app.tabBars.buttons["Você"].tap()
      var setting = app.switches["settings-collapsible-user-messages"]
      XCTAssertTrue(setting.waitForExistence(timeout: 10))
      app.swipeUp(velocity: .slow)
      XCTAssertEqual(setting.value as? String, "1")
      setting.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      wait(NSPredicate(format: "value == '0'"), on: setting)
      shot(app, "app-setting-disabled-" + theme)
      app.terminate()
      app = try launch(theme: theme, preference: nil)
      XCTAssertFalse(try toggle(app).exists)
      XCTAssertGreaterThan(try prompt(app).frame.height,
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 24) * 2)
      scrollAnswer(app, below: try prompt(app).frame.maxY, up: false)
      XCTAssertFalse(try toggle(app).exists)
      shot(app, "app-collapse-disabled-" + theme)
      app.buttons["Voltar"].tap()
      app.tabBars.buttons["Você"].tap()
      setting = app.switches["settings-collapsible-user-messages"]
      XCTAssertTrue(setting.waitForExistence(timeout: 10))
      app.swipeUp(velocity: .slow)
      XCTAssertEqual(setting.value as? String, "0")
      setting.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
      wait(NSPredicate(format: "value == '1'"), on: setting)
      app.terminate()
      app = try launch(theme: theme, preference: nil)
      XCTAssertEqual(try toggle(app).value as? String, "Recolhido")
      shot(app, "app-setting-enabled-" + theme)
      app.terminate()
    }
  }

  func testSearchStillHighlightsAndRevealsLongPrompt() throws {
    let app = try launch()
    app.buttons["Mais opções"].tap()
    app.buttons["Buscar na conversa"].tap()
    let field = app.textFields["conversation-search"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("detalhe final exclusivo")
    wait(NSPredicate(format: "label == '1 de 1'"), on: app.staticTexts["search-counter"])
    XCTAssertEqual(try toggle(app).value as? String, "Expandido")
    shot(app, "app-user-search-highlight")
    app.buttons["Cancelar"].tap()
    app.terminate()
  }
}
