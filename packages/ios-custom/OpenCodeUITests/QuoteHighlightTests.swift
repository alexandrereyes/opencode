import XCTest

@MainActor final class QuoteHighlightTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }
  private func launch(_ kind: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeOpenSession",
      try XCTUnwrap(environment["OPENCODE_QUOTE_" + kind])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    if let size = environment["OPENCODE_TEST_CONTENT_SIZE"] {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
    }
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)], timeout: 30), .completed)
    return app
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func marker(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
  }
  private func source(_ app: XCUIApplication, kind: String) throws -> XCUIElement {
    let id = try XCTUnwrap(environment["OPENCODE_QUOTE_" + kind + "_SOURCE"])
    return app.textViews["response-\(id)-\(id):text:0"]
  }
  func testPendingSelectionCommentDetailsEditAndRemove() throws {
    let app = try launch("PENDING")
    defer { app.terminate() }
    let response = try source(app, kind: "PENDING")
    XCTAssertTrue(response.waitForExistence(timeout: 15))
    let unmarkedWidth = response.frame.width
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).press(forDuration: 1)
    let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Selecionar Tudo'")).firstMatch
    if selectAll.exists { selectAll.tap() }
    let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'")).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Confira este trecho.")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForExistence(timeout: 10))
    XCTAssertTrue(marker(app).waitForExistence(timeout: 10))
    XCTAssertEqual(response.frame.width, unmarkedWidth, accuracy: 1)
    XCTAssertEqual(response.frame.width, app.frame.width - 32, accuracy: 1)
    XCTAssertEqual(marker(app).frame.width, 44, accuracy: 0.5)
    XCTAssertEqual(marker(app).frame.height, 44, accuracy: 0.5)
    screenshot("native-pending-mark")
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
    XCTAssertTrue(app.staticTexts["quote-detail-comment"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["quote-detail-comment"].label, "Confira este trecho.")
    screenshot("native-pending-details")
    app.buttons["quote-edit"].tap()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText(" Revisado.")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(marker(app).waitForExistence(timeout: 10))
    marker(app).tap()
    XCTAssertTrue(app.buttons["quote-remove"].waitForExistence(timeout: 5))
    app.buttons["quote-remove"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker(app))], timeout: 10), .completed)
    XCTAssertFalse(app.buttons["draft-quotes"].exists)
    screenshot("native-pending-removed")
  }
  func testSentMarkReopensAndNavigatesBothDirections() throws {
    let app = try launch("SENT")
    defer { app.terminate() }
    XCTAssertTrue(marker(app).waitForExistence(timeout: 15))
    screenshot("native-sent-mark")
    marker(app).tap()
    XCTAssertTrue(app.buttons["quote-go-message"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["quote-remove"].exists)
    XCTAssertTrue(app.buttons["quote-dismiss"].exists)
    screenshot("native-sent-details")
    app.buttons["quote-go-message"].tap()
    let carrier = try XCTUnwrap(environment["OPENCODE_QUOTE_SENT_CARRIER"])
    let reverse = app.buttons["quote-source-\(carrier)-0"]
    XCTAssertTrue(reverse.waitForExistence(timeout: 10))
    reverse.tap()
    XCTAssertTrue(marker(app).waitForExistence(timeout: 15))
    app.terminate()
    app.launch()
    XCTAssertTrue(marker(app).waitForExistence(timeout: 25))
    screenshot("native-sent-reopened")
  }
  func testRemovingSentMarkKeepsBubbleRecordAndSourceNavigation() throws {
    let app = try launch("REMOVABLE")
    defer { app.terminate() }
    XCTAssertTrue(marker(app).waitForExistence(timeout: 15))
    marker(app).tap()
    let dismiss = app.buttons["quote-dismiss"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
    XCTAssertEqual(dismiss.label, "Remover marcação")
    screenshot("native-removable-details")
    dismiss.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: marker(app))], timeout: 10), .completed)
    let response = try source(app, kind: "REMOVABLE")
    XCTAssertTrue(response.exists)
    screenshot("native-removable-removed")
    let carrier = try XCTUnwrap(environment["OPENCODE_QUOTE_REMOVABLE_CARRIER"])
    let reverse = app.buttons["quote-source-\(carrier)-0"]
    XCTAssertTrue(reverse.waitForExistence(timeout: 10))
    reverse.tap()
    XCTAssertTrue(response.waitForExistence(timeout: 15))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: response)], timeout: 10), .completed)
    XCTAssertFalse(marker(app).exists)
    screenshot("native-removable-source-revealed")
    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["quote-source-\(carrier)-0"].waitForExistence(timeout: 25))
    XCTAssertTrue(response.waitForExistence(timeout: 10))
    XCTAssertFalse(marker(app).exists)
    screenshot("native-removable-reopened")
  }
  func testRejectedSendKeepsDraftQuoteAndMark() throws {
    let app = XCUIApplication()
    let session = try XCTUnwrap(environment["OPENCODE_QUOTE_FAILING"])
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeOpenSession", session]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    // DEBUG transport, restricted to 4177/4183: only this Session's prompt endpoint answers 400.
    app.launchEnvironment["OPENCODE_TEST_COMPOSER_FAILURE"] = session
    app.launch()
    defer { app.terminate() }
    let response = try source(app, kind: "FAILING")
    XCTAssertTrue(response.waitForExistence(timeout: 25))
    XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 10))
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).press(forDuration: 1)
    let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'")).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Comentário que não será aceito.")
    app.buttons["Concluir"].tap()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Envio recusado de propósito.")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.staticTexts["send-error"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.buttons["draft-quotes"].exists)
    XCTAssertTrue(marker(app).exists)
    XCTAssertEqual(marker(app).value as? String, "rascunho")
    screenshot("native-rejected-send-kept")
  }
  func testSourceJumpLoadsOlderPages() throws {
    let app = try launch("PAGED")
    defer { app.terminate() }
    let carrier = try XCTUnwrap(environment["OPENCODE_QUOTE_PAGED_CARRIER"])
    let reverse = app.buttons["quote-source-\(carrier)-0"]
    XCTAssertTrue(reverse.waitForExistence(timeout: 15))
    reverse.tap()
    let response = try source(app, kind: "PAGED")
    XCTAssertTrue(response.waitForExistence(timeout: 30))
    XCTAssertTrue(marker(app).waitForExistence(timeout: 10))
    screenshot("native-paged-source")
  }
  func testMissingSourceKeepsCommentAndShowsUnavailableNotice() throws {
    let app = try launch("MISSING")
    defer { app.terminate() }
    let carrier = try XCTUnwrap(environment["OPENCODE_QUOTE_MISSING_CARRIER"])
    let reverse = app.buttons["quote-source-\(carrier)-0"]
    XCTAssertTrue(reverse.waitForExistence(timeout: 15))
    XCTAssertFalse(marker(app).exists)
    reverse.tap()
    XCTAssertTrue(app.staticTexts["O trecho citado não está mais disponível."].waitForExistence(timeout: 15))
    XCTAssertTrue(reverse.exists)
    screenshot("native-missing-source")
  }
  func testRestoredFullPassageDraftKeepsMultilineMarkAndTray() throws {
    let app = try launch("RESTORED")
    defer { app.terminate() }
    XCTAssertTrue(marker(app).waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["draft-quotes"].exists)
    XCTAssertLessThanOrEqual(app.buttons["draft-quotes"].frame.height, 18)
    XCTAssertEqual(marker(app).frame.width, 44, accuracy: 1)
    screenshot("native-full-pending-mark")
    app.buttons["draft-quotes"].tap()
    XCTAssertTrue(app.staticTexts["Citação 1"].waitForExistence(timeout: 5))
    screenshot("native-full-pending-tray")
    app.buttons["draft-quotes"].tap()
    var previous: CGRect?
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let frame = self.marker(app).frame
      defer { previous = frame }
      return previous == frame && self.marker(app).isHittable
    }, object: nil)], timeout: 5), .completed)
    marker(app).tap()
    XCTAssertTrue(app.buttons["quote-edit"].waitForExistence(timeout: 5))
    screenshot("native-full-pending-details")
    app.buttons["Fechar"].tap()
    app.terminate()
    app.launch()
    XCTAssertTrue(marker(app).waitForExistence(timeout: 25))
    screenshot("native-full-pending-reopened")
  }
  func testSeveralInlineMarkersKeepFullWidthAndOpenTheirOwnComments() throws {
    let app = try launch("MULTIPLE")
    defer { app.terminate() }
    let response = try source(app, kind: "MULTIPLE")
    let unmarked = app.textViews.matching(NSPredicate(format: "value == 'Decisão registrada.'")).firstMatch
    XCTAssertTrue(response.waitForExistence(timeout: 15))
    XCTAssertTrue(unmarked.exists)
    XCTAssertEqual(response.frame.width, unmarked.frame.width, accuracy: 1)
    XCTAssertEqual(response.frame.width, app.frame.width - 32, accuracy: 1)
    for (number, comment) in [(1, "Primeiro comentário."), (2, "Segundo comentário.")] {
      let inline = app.buttons.matching(NSPredicate(format: "label == %@", "Citação \(number)")).firstMatch
      XCTAssertTrue(inline.waitForExistence(timeout: 10))
      XCTAssertEqual(inline.frame.width, 44, accuracy: 0.5)
      inline.tap()
      XCTAssertTrue(app.staticTexts["quote-detail-comment"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.staticTexts["quote-detail-comment"].label, comment)
      app.buttons["Fechar"].tap()
    }
    screenshot("native-inline-multiple-full-width")
  }
}

@MainActor final class QuoteSendingTests: XCTestCase {
  func testAcknowledgedSendRemovesResponseMarkAndKeepsSourceNavigation() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    func shoot(_ name: String) {
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.name = name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "dark")
      shot.lifetime = .keepAlways
      add(shot)
    }
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeOpenSession",
      try XCTUnwrap(environment["OPENCODE_QUOTE_PENDING"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let source = try XCTUnwrap(environment["OPENCODE_QUOTE_PENDING_SOURCE"])
    let response = app.textViews["response-\(source)-\(source):text:0"]
    XCTAssertTrue(response.waitForExistence(timeout: 25))
    XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 10))
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).press(forDuration: 1)
    let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'")).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Comentário sintético de verificação.")
    app.buttons["Concluir"].tap()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Teste de interface: responda apenas OK, sem ferramentas e sem alterar arquivos.")
    let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    XCTAssertEqual(marker.value as? String, "rascunho")
    shoot("native-live-send-before")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["draft-quotes"])], timeout: 30), .completed)
    let reverse = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-source-'")).firstMatch
    XCTAssertTrue(reverse.waitForExistence(timeout: 30))
    XCTAssertFalse(marker.exists)
    shoot("native-live-send-acknowledged")
    reverse.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: response)], timeout: 20), .completed)
    XCTAssertFalse(marker.exists)
    shoot("native-live-send-source-revealed")
    app.terminate()
    app.launch()
    XCTAssertTrue(reverse.waitForExistence(timeout: 25))
    XCTAssertTrue(response.waitForExistence(timeout: 10))
    XCTAssertFalse(marker.exists)
    shoot("native-live-send-reopened")
  }
}
