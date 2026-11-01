import XCTest

/// The finished answer's footer (model, date, Copiar, Ouvir) whatever the answer's last block is, server-free.
@MainActor final class ResponseFooterTests: XCTestCase {
  private let app = XCUIApplication()

  /// A background subagent may keep working after the session went idle; the answer is finished all the same.
  func testFinishedAnswerShowsItsFooterWhateverItsLastBlock() throws {
    continueAfterFailure = false
    for document in ["markdown-end-table-only", "markdown-end-prose-table", "markdown-end-table-prose",
      "markdown-end-text", "markdown-end-code"]
    {
      let transcript = try launch(document, ["-OpenCodeFixtureFamilyWorking"])
      let footer = app.buttons["Copiar resposta"]
      XCTAssertTrue(footer.waitForExistence(timeout: 10), document)
      assertShown(footer, transcript: transcript, document)
      guard document == "markdown-end-prose-table" else { app.terminate(); continue }
      capture("footer-after-table")
      // The rows come back from above and from ↓ with the footer still shown.
      let viewport = app.transcriptViewport(transcript)
      let latest = app.buttons["Ir para a mais recente"]
      for _ in 0..<12 where !latest.exists { app.dragTranscript(transcript, viewport: viewport, delta: 120) }
      XCTAssertTrue(latest.waitForExistence(timeout: 3))
      latest.tap()
      Thread.sleep(forTimeInterval: 1.5)
      assertShown(footer, transcript: transcript, document + " depois de voltar ao fim")
      capture("footer-after-latest")
      app.terminate()
    }
  }

  /// No footer while the answer streams; it appears, whole, once the answer ends in a table.
  func testFooterAppearsWhenAStreamedAnswerEndsInATable() throws {
    continueAfterFailure = false
    let transcript = try launch("markdown-end-text",
      ["-OpenCodeFixtureStream", "120", "-OpenCodeFixtureStreamStop", "80"])
    let footer = app.buttons["Copiar resposta"]
    // The fixture's answer was finished until the stream reopens it.
    let streaming = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: footer)
    if XCTWaiter.wait(for: [streaming], timeout: 5) != .completed {
      let tree = XCTAttachment(string: app.debugDescription)
      tree.lifetime = .keepAlways
      add(tree)
      XCTFail("rodapé durante o streaming")
    }
    // About ten seconds of tokens; growth never scrolls, so the end is reached with ↓.
    let running = app.buttons["Parar"]
    let finished = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: running)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
    let latest = app.buttons["Ir para a mais recente"]
    if latest.waitForExistence(timeout: 3) { latest.tap() }
    XCTAssertTrue(footer.waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == 'Fim sintético'")).firstMatch.exists)
    Thread.sleep(forTimeInterval: 1)
    assertShown(footer, transcript: transcript, "depois do streaming")
    capture("footer-after-stream")
    app.terminate()
  }

  private func launch(_ document: String, _ extra: [String]) throws -> XCUIElement {
    app.launchArguments = ["-OpenCodeServerURL", ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177",
      "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "tail", "-OpenCodeMarkdownFixture",
      "-OpenCodeMarkdownFixtureDocument", document] + extra
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
    return transcript
  }

  private func assertShown(_ footer: XCUIElement, transcript: XCUIElement, _ message: String) {
    // The buttons' 44-point targets reach past the footer's line, which must be on screen above the composer.
    let viewport = app.transcriptViewport(transcript)
    XCTAssertTrue(viewport.insetBy(dx: 0, dy: -13).contains(footer.frame), "\(message): \(footer.frame) fora de \(viewport)")
    XCTAssertTrue(footer.isHittable, message)
  }

  private func capture(_ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
