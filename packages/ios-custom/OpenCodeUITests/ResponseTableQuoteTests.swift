import XCTest

/// A comment on a table cell opens from its mark like one in prose (same text view factory and tap), server-free.
@MainActor final class ResponseTableQuoteTests: XCTestCase {
  private let app = XCUIApplication()

  func testTableCellMarkOpensItsCommentAndSurvivesScrolling() throws {
    continueAfterFailure = false
    app.launchArguments = ["-OpenCodeServerURL", ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177",
      "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "tail", "-OpenCodeMarkdownFixture",
      "-OpenCodeMarkdownFixtureDocument", "markdown-end-prose-table"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"),
      evaluatedWith: transcript)], timeout: 25), .completed)
    let cell = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'capturas prontas'")).firstMatch
    XCTAssertTrue(cell.waitForExistence(timeout: 10))
    select(cell)
    let comment = app.menuItems["Comentar"]
    XCTAssertTrue(comment.waitForExistence(timeout: 5), app.debugDescription)
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Comentário sintético da célula.")
    app.buttons["Concluir"].tap()
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    capture("table-cell-mark")
    // One tap on the marked text, not only on its number, opens the comment.
    let detail = app.staticTexts["quote-detail-comment"]
    openFromText(cell, detail: detail)
    capture("table-cell-mark-details")
    // A selection in another cell is temporary: one tap on the marked text, or on its number, ends it and opens the
    // comment; a tap inside the selection keeps the native menu.
    func other(_ prefix: String) -> XCUIElement {
      app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch
    }
    selectWithMenu(other("concluído"))
    openFromText(cell, detail: detail)
    selectWithMenu(other("Exemplo A"))
    marker.tap()
    XCTAssertTrue(detail.waitForExistence(timeout: 5), "o número não abriu o comentário com seleção ativa")
    dismissDetail(detail)
    let inside = other("Exemplo B")
    selectWithMenu(inside)
    inside.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
    XCTAssertFalse(detail.waitForExistence(timeout: 2), "o toque dentro da seleção abriu um comentário")
    app.collectionViews["conversation-transcript"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    // Scrolled away and back (the table is rebuilt from pooled cell views): the mark still opens it.
    let viewport = app.transcriptViewport(transcript)
    for _ in 0..<4 { app.dragTranscript(transcript, viewport: viewport, delta: 120) }
    for _ in 0..<8 where !(cell.exists && cell.isHittable) { app.dragTranscript(transcript, viewport: viewport, delta: -120) }
    XCTAssertTrue(marker.waitForExistence(timeout: 5))
    openFromText(cell, detail: detail)
    marker.tap()
    XCTAssertTrue(detail.waitForExistence(timeout: 5))
    XCTAssertEqual(detail.label, "Comentário sintético da célula.")
    // The fixture Session keeps its draft between launches: leave it without the quote.
    app.buttons["quote-remove"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker)],
      timeout: 10), .completed)
  }

  /// Press and drag across the cell's first lines.
  private func select(_ cell: XCUIElement) {
    let origin = cell.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 6, dy: 12)).press(forDuration: 1,
      thenDragTo: origin.withOffset(CGVector(dx: cell.frame.width - 6, dy: 40)), withVelocity: .slow, thenHoldForDuration: 0.3)
  }

  /// A selection with its native menu. Selecting a text again after a comment sheet is covered by
  /// `ResponseSelectionTests/testTextSelectsAgainAfterAnotherTextsCommentOpens`.
  private func selectWithMenu(_ cell: XCUIElement) {
    select(cell)
    XCTAssertTrue(app.menuItems["Comentar"].waitForExistence(timeout: 5), "sem menu nativo na seleção")
  }

  private func openFromText(_ cell: XCUIElement, detail: XCUIElement) {
    cell.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
    XCTAssertTrue(detail.waitForExistence(timeout: 5), "o toque no texto marcado não abriu o comentário")
    XCTAssertEqual(detail.label, "Comentário sintético da célula.")
    dismissDetail(detail)
  }

  private func dismissDetail(_ detail: XCUIElement) {
    let close = app.buttons["Fechar"]
    if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: detail)],
      timeout: 5), .completed)
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
