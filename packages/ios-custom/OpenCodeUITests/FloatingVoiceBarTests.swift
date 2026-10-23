import XCTest

@MainActor final class FloatingVoiceBarTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private let app = XCUIApplication()
  private var bar: XCUIElement { app.descendants(matching: .any)["floating-voice-bar"] }
  private var session: String { ProcessInfo.processInfo.environment["OPENCODE_VOICE_BAR_SESSION"] ?? "" }

  private func launch(_ state: String, large: Bool = false, conversation: Bool = false) throws {
    let environment = ProcessInfo.processInfo.environment
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeVoiceBarFixture", state]
    if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
    if conversation { app.launchArguments += ["-OpenCodeOpenSession", session] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(bar.waitForExistence(timeout: 20))
  }
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func toggle() {
    bar.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 90, dy: 28)).tap()
  }
  private func control(_ trailing: CGFloat) {
    bar.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
      .withOffset(CGVector(dx: -trailing, dy: 29)).tap()
  }
  private func openConversation() {
    let row = app.buttons["session-row-" + session]
    app.revealVoiceRow(row)
    XCTAssertTrue(row.exists)
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    XCTAssertTrue(bar.exists)
  }

  func testControlsNavigationAndInsets() throws {
    try launch("speaking")
    XCTAssertFalse(app.buttons["master-accessory"].exists)
    XCTAssertTrue((bar.value as? String)?.hasPrefix("Compacta") == true)
    capture("controls-compact-sessions")
    let compact = bar.frame
    toggle()
    XCTAssertTrue((bar.value as? String)?.hasPrefix("Expandida") == true)
    XCTAssertGreaterThan(bar.frame.height, compact.height)
    capture("controls-expanded-sessions")
    XCTAssertEqual(bar.frame.width, compact.width, accuracy: 1)
    XCTAssertLessThanOrEqual(bar.frame.maxY, app.tabBars.firstMatch.frame.minY + 1)
    control(86)
    XCTAssertTrue(bar.label.contains("falando"))
    toggle()
    XCTAssertTrue((bar.value as? String)?.hasPrefix("Compacta") == true)
    openConversation()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(bar.frame.maxY, composer.frame.minY)
    toggle()
    XCTAssertLessThanOrEqual(bar.frame.maxY, composer.frame.minY)
    capture("controls-expanded-conversation")
    let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.15))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 70)))
    XCTAssertTrue((bar.value as? String)?.hasPrefix("Compacta") == true)
    app.buttons["Voltar"].tap()
    app.tabBars.buttons["Você"].tap()
    XCTAssertTrue(bar.exists)
    control(36)
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["master-accessory"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["master-accessory"].frame.width, compact.width, accuracy: 4)
    app.terminate()
  }

  func testMuteRetryAndLargeText() throws {
    try launch("listening", large: true)
    control(86)
    XCTAssertTrue(bar.label.contains("microfone desligado"))
    control(86)
    XCTAssertTrue(bar.label.contains("ouvindo"))
    toggle()
    capture("large-expanded-sessions")
    XCTAssertGreaterThanOrEqual(bar.frame.minX, 0)
    XCTAssertLessThanOrEqual(bar.frame.maxX, app.frame.maxX)
    app.terminate()
    try launch("listening", large: true, conversation: true)
    toggle()
    XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(bar.frame.maxY, app.textViews["conversation-composer"].frame.minY)
    capture("large-expanded-conversation")
    control(36)
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    app.terminate()
    try launch("error")
    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
      .withOffset(CGVector(dx: 0, dy: -28)).tap()
    XCTAssertTrue(bar.label.contains("ouvindo"))
    app.terminate()
  }

  func testKeyboardPlacement() throws {
    try launch("speaking", conversation: true)
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    toggle()
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(bar.frame.maxY, composer.frame.minY)
    capture("controls-expanded-keyboard")
    app.terminate()
  }

  func testKeyboardDismissalWithoutVoice() throws {
    try launch("speaking", conversation: true)
    control(36)
    XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.collectionViews["conversation-transcript"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    app.terminate()
  }

  func testKeyboardDismissalWithVoice() throws {
    try launch("speaking", conversation: true)
    toggle()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.collectionViews["conversation-transcript"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    XCTAssertTrue(bar.exists)
    app.terminate()
  }

  func testLastListRowRemainsReachable() throws {
    try launch("speaking")
    toggle()
    let list = app.collectionViews.firstMatch
    let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-row-"))
    var previous = ""
    var reached = false
    for _ in 0..<24 {
      list.swipeUp(velocity: .fast)
      guard let last = rows.allElementsBoundByIndex.last else { continue }
      if last.identifier == previous && last.frame.maxY <= bar.frame.minY {
        reached = true
        break
      }
      previous = last.identifier
    }
    XCTAssertTrue(reached, "A última sessão precisa ficar totalmente acima da faixa expandida")
    capture("last-row-expanded-sessions")
    app.terminate()
  }

  func testComposerCoverAndNewSessionPlacement() throws {
    try launch("speaking", conversation: true)
    XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 10))
    app.buttons["Adicionar"].tap()
    app.buttons["Expandir compositor"].tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForExistence(timeout: 5))
    XCTAssertTrue(bar.exists)
    XCTAssertLessThanOrEqual(bar.frame.maxY, app.textViews["conversation-composer"].frame.minY)
    capture("fullscreen-composer")
    app.buttons["Recolher"].tap()
    app.buttons["Voltar"].tap()
    app.buttons["Nova sessão"].tap()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    XCTAssertTrue(bar.exists)
    XCTAssertLessThanOrEqual(bar.frame.maxY, composer.frame.minY)
    capture("new-session")
    app.terminate()
  }

  func testCaptureEveryState() throws {
    for state in ["listening", "speaking", "thinking", "connecting", "reconnecting", "muted", "error", "idle", "long", "interrupted"] {
      try launch(state)
      let origin = app.coordinate(withNormalizedOffset: .zero)
      origin.withOffset(CGVector(dx: 200, dy: 600)).press(forDuration: 0.05,
        thenDragTo: origin.withOffset(CGVector(dx: 200, dy: 220)))
      capture(state + "-compact-sessions")
      toggle()
      capture(state + "-expanded-sessions")
      app.terminate()
      try launch(state, conversation: true)
      XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 10))
      toggle()
      capture(state + "-expanded-conversation")
      toggle()
      capture(state + "-compact-conversation")
      app.terminate()
    }
  }
}
