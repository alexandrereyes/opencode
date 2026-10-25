import XCTest

/// "Pergunta paralela" opens at full height ready to type, over an opaque composer (offline conversation fixture).
@MainActor final class SideQuestionTests: XCTestCase {
  private let app = XCUIApplication()
  private var theme: String { ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  // A missing focus or full height is reported, then the remaining checks still run.
  override func setUp() { continueAfterFailure = true }

  func testSelectionOpensReadyToTypeAndTheComposerHidesNoAnswer() throws {
    try launch()
    defer { app.terminate() }
    let response = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH %@", "✨ Formatação no OpenChamber")).firstMatch
    XCTAssertTrue(response.waitForExistence(timeout: 10))
    let origin = response.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 40, dy: 70))
      .press(forDuration: 1, thenDragTo: origin.withOffset(CGVector(dx: 140, dy: 160)), withVelocity: .slow, thenHoldForDuration: 0.3)
    menu("Pergunta paralela").tap()
    let field = expectReadyToType("selection")

    field.typeText("Não entendi")
    app.buttons["Enviar pergunta paralela"].tap()
    let copy = app.scrollViews["side-question-scroll"].buttons["Copiar resposta"]
    XCTAssertTrue(copy.waitForExistence(timeout: 10))
    // Sending dismisses the keyboard; the sheet keeps its full height.
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 5), .completed)
    expectFullHeight()
    let card = app.otherElements.matching(identifier: "side-question-card").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    settle()
    capture("side-answer-bottom")
    // The answer scrolls to its end above the composer.
    XCTAssertLessThanOrEqual(copy.frame.maxY, card.frame.minY + 0.5)

    // Scrolling the answer behind the composer does not change a single composer pixel.
    let resting = pixels(card)
    let scroll = app.scrollViews["side-question-scroll"]
    scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
      .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
    settle()
    capture("side-answer-behind-composer")
    let scrolled = pixels(card)
    XCTAssertLessThan(difference(resting, scrolled), 0.002, "O texto da resposta aparece através do compositor")

    // With the keyboard open, the end of the answer still clears the composer.
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    // Drag only between the sheet's bar and the composer: a drag over the keyboard would slide-type.
    let screen = app.coordinate(withNormalizedOffset: .zero)
    for _ in 0..<4 {
      screen.withOffset(CGVector(dx: scroll.frame.midX, dy: card.frame.minY - 30))
        .press(forDuration: 0.1, thenDragTo: screen.withOffset(CGVector(dx: scroll.frame.midX, dy: scroll.frame.minY + 30)))
    }
    if !app.keyboards.firstMatch.exists { field.tap() }
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    settle()
    capture("side-answer-keyboard")
    XCTAssertTrue(copy.isHittable)
    XCTAssertLessThanOrEqual(copy.frame.maxY, card.frame.minY + 0.5)
    XCTAssertLessThanOrEqual(card.frame.maxY, app.keyboards.firstMatch.frame.minY + 0.5)
  }

  func testSlashCommandOpensReadyToTypeWithAndWithoutAQuestion() throws {
    try launch()
    defer { app.terminate() }
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
    // The fixture Session keeps its draft between launches.
    if let text = composer.value as? String, !text.isEmpty {
      composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }
    composer.typeText("/btw")
    let suggestion = app.buttons["suggestion-btw"]
    XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
    suggestion.tap()
    expectReadyToType("slash")
    app.buttons["Fechar"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.textViews["side-question-composer"])], timeout: 5), .completed)

    composer.tap()
    composer.typeText("/btw Qual é a ordem dos passos?")
    let send = app.buttons["composer-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.tap()
    // The submitted question is already asked; the field is ready for the next one.
    expectReadyToType("slash-question")
    XCTAssertTrue(app.scrollViews["side-question-scroll"].buttons["Copiar resposta"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    expectFullHeight()
    capture("side-open-slash-question-answered")
  }

  private func launch() throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture",
      "-OpenCodeSideQuestionFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)], timeout: 25), .completed)
  }

  /// Full height, focused field and keyboard, without any touch after opening.
  @discardableResult private func expectReadyToType(_ entry: String) -> XCUIElement {
    let field = app.textViews["side-question-composer"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)], timeout: 5), .completed, "Campo sem foco (\(entry))")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Teclado fechado (\(entry))")
    expectFullHeight()
    settle()
    capture("side-open-\(entry)")
    if !app.keyboards.firstMatch.exists {
      field.tap()
      _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
    }
    return field
  }

  /// A large detent puts the sheet's bar near the top; medium leaves it around mid-screen.
  private func expectFullHeight() {
    let bar = app.navigationBars["Pergunta paralela"]
    XCTAssertTrue(bar.waitForExistence(timeout: 5))
    XCTAssertLessThan(bar.frame.minY, app.windows.firstMatch.frame.height * 0.2)
  }

  private func settle() { _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 1) }

  /// The edit menu's item; transcript icons may carry the same label.
  private func menu(_ label: String) -> XCUIElement {
    let item = app.menuItems[label]
    if item.waitForExistence(timeout: 5) { return item }
    let fallback = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
      .allElementsBoundByIndex.first { $0.elementType != .image && $0.isHittable }
    return try! XCTUnwrap(fallback, "Menu sem \(label)")
  }

  private func pixels(_ element: XCUIElement) -> (width: Int, height: Int, bytes: [UInt8]) {
    let image = element.screenshot().image.cgImage!
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, bytes)
  }

  /// Fraction of pixels whose color moved by more than a few levels.
  private func difference(_ a: (width: Int, height: Int, bytes: [UInt8]), _ b: (width: Int, height: Int, bytes: [UInt8])) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let changed = stride(from: 0, to: a.bytes.count, by: 4).filter { index in
      (0..<3).contains { abs(Int(a.bytes[index + $0]) - Int(b.bytes[index + $0])) > 6 }
    }.count
    return Double(changed) / Double(a.width * a.height)
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name + "-" + theme
    image.lifetime = .keepAlways
    add(image)
  }
}
