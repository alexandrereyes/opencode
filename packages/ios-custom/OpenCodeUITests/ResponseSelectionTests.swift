import XCTest

/// Selection in an agent response spans its paragraphs, headings and lists (offline Markdown fixture).
@MainActor final class ResponseSelectionTests: XCTestCase {
  private let app = XCUIApplication()
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  override func setUp() { continueAfterFailure = false }

  func testSelectionFromOneParagraphToAnotherCopiesAndComments() throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    // The fixture Session keeps its draft between launches; start from a clean one.
    launch()
    if resetDraft() {
      app.terminate()
      launch()
    }
    defer { app.terminate() }
    let response = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH %@", "✨ Formatação no OpenChamber")).firstMatch
    XCTAssertTrue(response.waitForExistence(timeout: 10))
    // The title, the introduction, the next heading and its paragraphs are one text.
    XCTAssertTrue((response.value as? String ?? "").contains("simples.\n\n1. Destaques no texto\n\nVocê pode usar"))

    select(in: response)
    capture("response-selection-across-heading")
    menu("Comentar").tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Comentário sobre vários parágrafos.")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForExistence(timeout: 10))
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    // The quotation ends in the paragraph after the heading, inside the same response text.
    XCTAssertGreaterThan(marker.frame.midY, response.frame.minY + 150)
    XCTAssertLessThan(marker.frame.midY, response.frame.maxY)
    capture("response-selection-commented")

    select(in: response)
    menu("Copiar").tap()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.press(forDuration: 1.2)
    menu("Colar").tap()
    let pasted = try XCTUnwrap(composer.value as? String)
    XCTAssertTrue(pasted.contains("mostruário"), pasted)
    XCTAssertTrue(pasted.contains("\n\n1. Destaques no texto\n\n"), pasted)
    XCTAssertTrue(pasted.contains("Você pode"), pasted)
    capture("response-selection-pasted")
    // Remove the quotation and the pasted text from a fresh screen, where the mark is visible.
    app.terminate()
    launch()
    resetDraft()
  }

  /// A saved quote stays one tap away while the reader selects other text (Alexandre, 01/11): the selection keeps its
  /// menu, a tap inside it stays native, and a tap on the mark or its number ends the selection and opens the comment.
  func testSelectionElsewhereNeverBlocksTheSavedComment() throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    launch()
    if resetDraft() {
      app.terminate()
      launch()
    }
    defer { app.terminate() }
    let response = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH %@", "✨ Formatação no OpenChamber")).firstMatch
    XCTAssertTrue(response.waitForExistence(timeout: 10))
    let origin = response.coordinate(withNormalizedOffset: .zero)
    // The introduction's first line, below the title.
    origin.withOffset(CGVector(dx: 40, dy: 52))
      .press(forDuration: 1, thenDragTo: origin.withOffset(CGVector(dx: 300, dy: 52)), withVelocity: .slow, thenHoldForDuration: 0.3)
    menu("Comentar").tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Comentário salvo.")
    app.buttons["Concluir"].tap()
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    let detail = app.staticTexts["quote-detail-comment"]
    let marked = response.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 120, dy: 52))
    let word = response.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 120, dy: 360))
    func opensWithOneTap(_ target: XCUICoordinate, _ name: String) {
      target.tap()
      XCTAssertTrue(detail.waitForExistence(timeout: 3), "\(name): um toque abre o comentário")
      XCTAssertEqual(detail.label, "Comentário salvo.")
      capture("quote-one-tap-" + name)
      app.buttons["Fechar"].tap()
      XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
      XCTAssertTrue(marker.exists, "\(name): a marcação continua")
    }
    func selectWord() {
      word.press(forDuration: 1)
      let shown = app.menuItems["Comentar"].waitForExistence(timeout: 5)
        || app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'"))
          .allElementsBoundByIndex.contains { $0.elementType != .image && $0.isHittable }
      XCTAssertTrue(shown, "A seleção mantém o menu nativo")
    }

    opensWithOneTap(marked, "sem-selecao")
    selectWord()
    capture("quote-selection-elsewhere")
    opensWithOneTap(marked, "marca-com-selecao")
    selectWord()
    opensWithOneTap(marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), "numero-com-selecao")
    // A tap inside the selection keeps the native behavior and opens nothing.
    selectWord()
    word.tap()
    XCTAssertFalse(detail.waitForExistence(timeout: 2), "Tocar dentro da seleção não abre o comentário")
    opensWithOneTap(marked, "depois-de-tocar-na-selecao")
    // Neither a tap outside the texts nor a drag of the conversation leaves a hidden selection behind.
    selectWord()
    let transcript = app.collectionViews["conversation-transcript"]
    transcript.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: 6, dy: response.frame.minY + 200 - transcript.frame.minY)).tap()
    opensWithOneTap(marked, "depois-da-margem")
    selectWord()
    transcript.swipeUp(velocity: .slow)
    transcript.swipeDown(velocity: .slow)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: marker)], timeout: 5), .completed)
    opensWithOneTap(response.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 120, dy: 52)), "depois-de-rolar")
    app.terminate()
    launch()
    resetDraft()
  }

  private func launch() {
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)], timeout: 25), .completed)
  }

  /// Clears composer text and quotation marks this test leaves in the fixture draft.
  @discardableResult private func resetDraft() -> Bool {
    var changed = false
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    while marker.waitForExistence(timeout: 2) {
      marker.tap()
      let remove = app.buttons["quote-remove"]
      XCTAssertTrue(remove.waitForExistence(timeout: 5))
      remove.tap()
      _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker)], timeout: 5)
      changed = true
    }
    let composer = app.textViews["conversation-composer"]
    if let text = composer.value as? String, !text.isEmpty {
      composer.tap()
      composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
      // Leaving the foreground persists the cleared draft before the app is terminated.
      XCUIDevice.shared.press(.home)
      _ = app.wait(for: .runningBackground, timeout: 5)
      app.activate()
      changed = true
    }
    return changed
  }

  func testSearchMovesThroughMatchesInsideJoinedProse() throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    launch()
    defer { app.terminate() }
    app.openConversationOptions(expect: "Buscar na conversa").tap()
    let field = app.textFields["conversation-search"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    // "citação" occurs in several paragraphs and list items of one joined text (section 4).
    field.typeText("citação")
    let counter = app.staticTexts["search-counter"]
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH '1 de '"), evaluatedWith: counter)], timeout: 10), .completed)
    let total = try XCTUnwrap(Int(counter.label.components(separatedBy: " de ").last ?? ""))
    XCTAssertGreaterThanOrEqual(total, 3)
    let section = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value CONTAINS 'Uma citação também pode ter vários parágrafos'")).firstMatch
    for index in 2...3 {
      app.buttons["Próximo resultado"].tap()
      XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH %@", "\(index) de "), evaluatedWith: counter)], timeout: 10), .completed)
      // Each match inside the joined text is brought on screen.
      XCTAssertTrue(section.waitForExistence(timeout: 5))
      XCTAssertLessThan(section.frame.minY, app.transcriptViewport(app.collectionViews["conversation-transcript"]).maxY)
      capture("response-search-\(index)")
    }
  }

  /// Long-press the introduction's first line ("Um pequeno mostruário", below the title) and drag past the
  /// "1. Destaques no texto" heading.
  private func select(in response: XCUIElement) {
    let origin = response.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 40, dy: 52))
      .press(forDuration: 1, thenDragTo: origin.withOffset(CGVector(dx: 140, dy: 290)), withVelocity: .slow, thenHoldForDuration: 0.3)
  }

  /// The edit menu's item; transcript icons may carry the same label.
  private func menu(_ label: String) -> XCUIElement {
    let item = app.menuItems[label]
    if item.waitForExistence(timeout: 5) { return item }
    let fallback = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
      .allElementsBoundByIndex.first { $0.elementType != .image && $0.isHittable }
    return try! XCTUnwrap(fallback, "Menu sem \(label)")
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name + "-" + theme
    image.lifetime = .keepAlways
    add(image)
  }
}
