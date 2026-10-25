import XCTest

/// The offline fixture opens at msg_scroll_0148's turn: tool steps, then a long final answer below its divider.
@MainActor final class PinnedPromptJumpTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testPinnedPromptReturnsToTheStartOfItsTurnInBothThemes() throws {
    let id = "msg_scroll_0148"
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
        "-OpenCodeFixturePosition", "middle", "-OpenCodeTheme", theme,
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      settle()
      let header = transcript.cells.containing(.any, identifier: "user-content-" + id).firstMatch
      // The turn's first row holds its tool steps; the final answer and its divider come after it.
      let start = transcript.cells.containing(NSPredicate(format: "identifier BEGINSWITH 'tool-group-context:msg_scroll_0149'")).firstMatch
      let answer = transcript.cells.containing(.button, identifier: "read-aloud-message-msg_scroll_0151").firstMatch
      let text = app.descendants(matching: .any)["user-prompt-" + id]
      let toggle = app.buttons["user-prompt-toggle-" + id]
      var pinned: Bool { abs(header.frame.minY - transcript.frame.minY) <= 1 }
      var atStart: Bool { start.exists && abs(start.frame.minY - header.frame.maxY) <= 1.5 }
      func card() -> XCUICoordinate {
        // The bubble's padding, beside the prompt text: the bubble's own tap rather than the text's.
        let content = app.descendants(matching: .any)["user-content-" + id].frame
        return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: content.minX - 7, dy: content.midY))
      }
      func unmoved(_ y: CGFloat, _ message: String) {
        settle()
        XCTAssertTrue(pinned, message)
        XCTAssertEqual(answer.frame.minY, y, accuracy: 1, message)
        XCTAssertFalse(atStart, message)
      }

      XCTAssertTrue(pinned)
      XCTAssertTrue(atStart, "The restored turn starts below its prompt")
      let restored = answer.frame.minY
      text.tap()
      settle()
      XCTAssertEqual(answer.frame.minY, restored, accuracy: 1, "Already at the start, nothing scrolls")
      XCTAssertEqual(toggle.value as? String, "Recolhido")

      for _ in 0..<3 { drag(app, transcript, by: 120) }
      settle()
      XCTAssertTrue(pinned)
      XCTAssertFalse(atStart)
      let reading = answer.frame.minY
      shot(app, "pinned-reading-" + theme)
      app.buttons["user-revert-" + id].tap()
      let alert = app.alerts["Redefinir para este ponto?"]
      XCTAssertTrue(alert.waitForExistence(timeout: 5))
      alert.buttons["Cancelar"].tap()
      XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
      unmoved(reading, "Redefinir keeps the reading position")
      app.buttons["user-copy-" + id].tap()
      unmoved(reading, "Copiar keeps the reading position")
      toggle.tap()
      XCTAssertEqual(toggle.value as? String, "Expandido")
      settle()
      XCTAssertTrue(pinned)
      XCTAssertFalse(atStart, "Mostrar mensagem completa expands without scrolling")
      toggle.tap()
      XCTAssertEqual(toggle.value as? String, "Recolhido")
      unmoved(reading, "Mostrar menos keeps the reading position")

      text.tap()
      XCTAssertTrue(wait { atStart }, "The pinned prompt's text returns to the turn's first row")
      XCTAssertTrue(pinned)
      XCTAssertEqual(toggle.value as? String, "Recolhido", "A pinned prompt's text scrolls instead of expanding")
      shot(app, "pinned-jumped-" + theme)

      // Far enough that the turn's first row is no longer laid out.
      for _ in 0..<12 where answer.frame.minY > transcript.frame.minY - 1600 { drag(app, transcript, by: 300) }
      settle()
      XCTAssertTrue(pinned)
      XCTAssertFalse(start.exists && start.frame.maxY > transcript.frame.minY - 600)
      card().tap()
      XCTAssertTrue(wait { atStart }, "The bubble around the text returns from a distant row")
      XCTAssertTrue(pinned)
      shot(app, "pinned-far-jumped-" + theme)

      drag(app, transcript, by: -120)
      settle()
      XCTAssertGreaterThan(header.frame.minY, transcript.frame.minY + 40)
      let inline = (header: header.frame.minY, answer: answer.frame.minY)
      card().tap()
      settle()
      XCTAssertEqual(header.frame.minY, inline.header, accuracy: 1, "An inline prompt does not scroll")
      XCTAssertEqual(answer.frame.minY, inline.answer, accuracy: 1)
      text.tap()
      XCTAssertEqual(toggle.value as? String, "Expandido", "An inline prompt's text still expands")
      toggle.tap()
      XCTAssertEqual(toggle.value as? String, "Recolhido")
      app.terminate()
    }
  }

  /// msg_scroll_0159's turn has dozens of steps: opened at its final answer, the first row is not laid out.
  func testDistantTurnStartIsRevealedByIdentityInBothThemes() throws {
    let id = "msg_scroll_0159"
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
        "-OpenCodeFixturePosition", "msg_scroll_0204", "-OpenCodeTheme", theme,
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      settle()
      let header = transcript.cells.containing(.any, identifier: "user-content-" + id).firstMatch
      let start = transcript.cells.containing(NSPredicate(format: "identifier CONTAINS 'msg_scroll_0160'")).firstMatch
      XCTAssertTrue(header.exists)
      XCTAssertEqual(header.frame.minY, transcript.frame.minY, accuracy: 1)
      XCTAssertFalse(start.exists)
      app.descendants(matching: .any)["user-prompt-" + id].tap()
      XCTAssertTrue(wait { start.exists && abs(start.frame.minY - header.frame.maxY) <= 1.5 })
      XCTAssertEqual(header.frame.minY, transcript.frame.minY, accuracy: 1)
      shot(app, "pinned-identity-jumped-" + theme)
      app.terminate()
    }
  }

  /// A slow drag in the gutter, held so it never flings; a positive distance reads further down. It stays inside
  /// the area below the pinned prompt, which a draft left in the composer can shrink.
  private func drag(_ app: XCUIApplication, _ transcript: XCUIElement, by requested: CGFloat) {
    let viewport = app.transcriptViewport(transcript)
    let distance = min(abs(requested), viewport.height * 0.7) * (requested < 0 ? -1 : 1)
    let from = transcript.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: 32, dy: viewport.midY + distance / 2 - transcript.frame.minY))
    from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -distance)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
  }
  private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }
  private func wait(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
