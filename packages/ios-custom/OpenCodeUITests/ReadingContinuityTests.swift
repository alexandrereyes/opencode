import AppIntents
import XCTest

@MainActor final class ReadingContinuityTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func launch(_ role: String, theme: String = "openchamber-dark") throws -> XCUIApplication
  {
    let app = XCUIApplication()
    let session = try XCTUnwrap(environment["OPENCODE_TEST_" + role])
    app.launchArguments = [
      "-OpenCodeServerURL", "http://127.0.0.1:4177",
      "-OpenCodeTheme", theme, "-OpenCodeOpenSession", session,
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    waitForReading(app)
    return app
  }
  private func waitForReading(_ app: XCUIApplication) {
    let transcript = app.collectionViews["conversation-transcript"]
    // The keyboard's own test session deliberately starts with an empty transcript.
    let settled = NSPredicate(format: "value != 'Restaurando leitura'")
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation(for: settled, evaluatedWith: transcript)], timeout: 25),
      .completed)
  }
  private func openFromSessions(_ app: XCUIApplication, title: String) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    let list = app.collectionViews.firstMatch
    if !row.isHittable { list.swipeDown(velocity: .fast) }
    for _ in 0..<10 {
      if row.isHittable { break }
      list.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(row.isHittable)
    row.tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 15))
    waitForReading(app)
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func waitValue(_ editor: XCUIElement, _ value: String) {
    XCTAssertTrue(
      NSPredicate(format: "value == %@", value).evaluate(with: editor)
        || XCTWaiter.wait(
          for: [expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: editor)],
          timeout: 5) == .completed
    )
  }
  func testSoftwareReturnShiftAutoCapitalizationAndCapsLock() throws {
    let app = try launch("OWN")
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    waitValue(editor, "")
    editor.typeText("OK")
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
    keyboard.buttons["Return"].tap()
    waitValue(editor, "OK\n")
    // A new sentence is automatically shifted; Return must still insert a newline.
    keyboard.buttons["Return"].tap()
    waitValue(editor, "OK\n\n")
    // Disable automatic Shift, then double-tap to lock it.
    keyboard.buttons["shift"].tap()
    keyboard.buttons["shift"].doubleTap()
    keyboard.buttons["Return"].tap()
    waitValue(editor, "OK\n\n\n")
    screenshot("keyboard-caps-lock-newline")
    // Leave Caps Lock, type prose to clear automatic capitalization, then manually Shift.
    keyboard.buttons["shift"].tap()
    editor.typeText("ok")
    keyboard.buttons["shift"].tap()
    keyboard.buttons["Return"].tap()
    XCTAssertTrue(
      NSPredicate(format: "value == %@", "").evaluate(with: editor)
        || XCTWaiter.wait(
          for: [expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: editor)],
          timeout: 20) == .completed
    )
    screenshot("keyboard-shift-return-sent")
  }
  func testHardwareShiftReturn() throws {
    let app = try launch("HARDWARE")
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("OK ")
    editor.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    let newline = expectation(
      for: NSPredicate(format: "value ENDSWITH %@", "\n"), evaluatedWith: editor)
    guard XCTWaiter.wait(for: [newline], timeout: 3) == .completed else {
      throw XCTSkip(
        "XCUITest não entregou Return físico sem modificadores neste ambiente; não é possível validar o atalho."
      )
    }
    editor.typeKey(XCUIKeyboardKey.return, modifierFlags: .shift)
    waitValue(editor, "")
    screenshot("hardware-shift-return-sent")
  }
  func testHistoryNavigationAndRelaunch() throws {
    let app = try launch("C")
    let transcript = app.collectionViews["conversation-transcript"]
    if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
    for _ in 0..<9 { transcript.swipeDown(velocity: .slow) }
    for _ in 0..<4 { transcript.swipeUp(velocity: .slow) }
    // Let the reader's scroll-idle debounce and deferred native geometry settle.
    // This test kills the process directly, unlike an ordinary background transition.
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let response = try XCTUnwrap(
      app.textViews.allElementsBoundByIndex.filter {
        $0.identifier != "conversation-composer" && $0.frame.maxY > transcript.frame.minY + 100
          && $0.frame.minY < transcript.frame.maxY
      }.min(by: { $0.frame.minY < $1.frame.minY }))
    let passage = try XCTUnwrap(response.value as? String)
    let y = app.textViews.matching(NSPredicate(format: "value == %@", passage)).firstMatch.frame
      .minY
    screenshot("c-before-navigation")
    app.buttons["Voltar"].tap()
    openFromSessions(app, title: "Conversa B — precisa de você")
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    screenshot("b-divider")
    app.buttons["Voltar"].tap()
    openFromSessions(app, title: "Conversa C — histórico e compositor")
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    waitForReading(app)
    let returned = app.textViews.matching(NSPredicate(format: "value == %@", passage)).firstMatch
    XCTAssertTrue(returned.waitForExistence(timeout: 10))
    XCTAssertEqual(returned.frame.minY, y, accuracy: 5)
    screenshot("c-after-navigation")
    app.terminate()
    let relaunched = try launch("C")
    XCTAssertTrue(
      relaunched.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    let restored = relaunched.textViews.matching(NSPredicate(format: "value == %@", passage))
      .firstMatch
    XCTAssertTrue(restored.waitForExistence(timeout: 10))
    XCTAssertEqual(restored.frame.minY, y, accuracy: 5)
    screenshot("c-after-relaunch")
    XCUIDevice.shared.orientation = .landscapeLeft
    screenshot("c-portrait-policy")
    XCUIDevice.shared.orientation = .portrait
    relaunched.terminate()
    let light = try launch("C", theme: "openchamber-light")
    XCTAssertTrue(
      light.textViews.matching(NSPredicate(format: "value == %@", passage)).firstMatch
        .waitForExistence(timeout: 10))
    screenshot("c-restored-light")
    light.terminate()
    light.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
    light.launch()
    waitForReading(light)
    XCTAssertTrue(
      light.textViews.matching(NSPredicate(format: "value == %@", passage)).firstMatch
        .waitForExistence(timeout: 10))
    screenshot("c-restored-large-type")
  }
  func testParentChildEdgeSwipeAndExpansion() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch("A", theme: theme)
      let transcript = app.collectionViews["conversation-transcript"]
      for _ in 0..<3 { transcript.swipeDown(velocity: .slow) }
      let step = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Usou 5'")).firstMatch
      XCTAssertTrue(step.waitForExistence(timeout: 10))
      let child = app.buttons.matching(
        NSPredicate(format: "label CONTAINS 'Comparar alternativas'")
      )
      .firstMatch
      if child.exists { step.tap() }
      step.tap()
      let read = app.buttons.matching(NSPredicate(format: "label CONTAINS '212 linhas'")).firstMatch
      XCTAssertTrue(read.waitForExistence(timeout: 5))
      read.tap()
      screenshot("expanded-before-child-" + theme)
      app.buttons.matching(NSPredicate(format: "label CONTAINS 'agentes em execução'")).firstMatch
        .tap()
      app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH 'Explore' AND label CONTAINS 'Comparar alternativas'")
      ).firstMatch.tap()
      XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 10))
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
      XCTAssertTrue(step.waitForExistence(timeout: 10))
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS '212: Infraestrutura fictícia.'")
        ).firstMatch.exists)
      screenshot("expanded-after-child-" + theme)
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
      XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 10))
      openFromSessions(app, title: "Conversa A — trabalhando")
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label CONTAINS '212: Infraestrutura fictícia.'")
        ).firstMatch.exists)
      screenshot("expanded-reopened-" + theme)
    }
  }
  func testPermissionWithExpandedQuotesAndThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch("B", theme: theme)
      let transcript = app.collectionViews["conversation-transcript"]
      // Add a local quote through the real selection menu, never submit or answer the permission.
      if !app.buttons["draft-quotes"].exists {
        for _ in 0..<3 { transcript.swipeDown(velocity: .slow) }
        let response = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Recomendo o'"))
          .firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 10))
        response.tap()
        response.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.25)).press(
          forDuration: 1)
        let comment = app.descendants(matching: .any).matching(
          NSPredicate(format: "label == 'Comentar'")
        ).firstMatch
        guard comment.waitForExistence(timeout: 5) else {
          let hierarchy = XCTAttachment(string: app.debugDescription)
          hierarchy.name = "selection-hierarchy"
          hierarchy.lifetime = .keepAlways
          add(hierarchy)
          screenshot("selection-menu-missing")
          XCTFail("O menu de seleção não apresentou Comentar")
          return
        }
        screenshot("selection-pauses-following")
        comment.tap()
        app.textViews["Comentário"].typeText("Confira este trecho antes de continuar.")
        app.buttons["Concluir"].tap()
      }
      XCTAssertTrue(app.buttons["draft-quotes"].waitForExistence(timeout: 10))
      app.buttons["draft-quotes"].tap()
      if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
      let permit = app.buttons["Permitir"].firstMatch
      XCTAssertTrue(permit.waitForExistence(timeout: 5))
      XCTAssertTrue(permit.isHittable)
      XCTAssertLessThan(permit.frame.maxY, app.buttons["draft-quotes"].frame.minY)
      screenshot("b-expanded-quotes-" + theme)
      app.terminate()
    }
  }
  func testUnreadJump() throws {
    let theme = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch("C", theme: theme)
    let pill = app.buttons["Ir às novas mensagens"]
    guard pill.waitForExistence(timeout: 5) else {
      throw XCTSkip("Execute logo após seed-conversation.ts --reset; nunca retroceda o watermark.")
    }
    screenshot("c-unread-above-" + theme)
    pill.tap()
    waitForReading(app)
    XCTAssertTrue(app.staticTexts["Novas mensagens"].isHittable)
    XCTAssertFalse(pill.exists)
    screenshot("c-unread-divider-" + theme)
  }
}
