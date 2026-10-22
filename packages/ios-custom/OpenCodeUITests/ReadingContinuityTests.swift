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
  private func codeUnderHeader(_ snapshot: any XCUIElementSnapshot, cutoff: CGFloat) -> Bool {
    if (snapshot.value as? String)?.contains("image: makeplane/plane:stable") == true,
      snapshot.frame.height > 0, snapshot.frame.minY < cutoff, snapshot.frame.maxY > cutoff
    {
      return true
    }
    return snapshot.children.contains { codeUnderHeader($0, cutoff: cutoff) }
  }
  func testSoftwareReturnShiftAutoCapitalizationAndCapsLock() throws {
    let theme = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch("OWN", theme: theme)
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
    screenshot("keyboard-caps-lock-newline-" + theme)
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
    screenshot("keyboard-shift-return-sent-" + theme)
  }
  func testHistoryNavigationAndRelaunch() throws {
    let theme = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch("C", theme: theme)
    let transcript = app.collectionViews["conversation-transcript"]
    if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
    for _ in 0..<20 { transcript.swipeDown(velocity: .slow) }
    for _ in 0..<4 { transcript.swipeUp(velocity: .slow) }
    // Let the reader's scroll-idle debounce and deferred native geometry settle.
    // This test kills the process directly, unlike an ordinary background transition.
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let response = try XCTUnwrap(
      app.textViews.allElementsBoundByAccessibilityElement.filter {
        $0.identifier.hasPrefix("response-") && $0.frame.maxY > transcript.frame.minY + 110
          && $0.frame.minY < transcript.frame.maxY
      }.min(by: { $0.frame.minY < $1.frame.minY }))
    let passage = try XCTUnwrap(response.value as? String)
    let revision = try XCTUnwrap(passage.firstMatch(of: /Revisão (\d+) concluída/))
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(Int(revision.1)), 20,
      "A âncora deve exigir páginas antigas, não apenas a página inicial do fim.")
    let identifier = response.identifier
    let y = app.textViews[identifier].frame.minY
    var offsets: [CGFloat] = []
    screenshot("c-original-" + theme)
    for cycle in 1...5 {
      app.buttons["Voltar"].tap()
      openFromSessions(app, title: "Conversa C — histórico e compositor")
      let returned = app.textViews[identifier]
      XCTAssertTrue(returned.waitForExistence(timeout: 10))
      XCTAssertEqual(returned.value as? String, passage)
      offsets.append(returned.frame.minY - y)
      XCTAssertEqual(returned.frame.minY, y, accuracy: 24)
      screenshot("c-cycle-\(cycle)-" + theme)
    }
    // A small systematic difference is tolerable; a restore must never creep.
    XCTAssertLessThanOrEqual((offsets.max() ?? 0) - (offsets.min() ?? 0), 2)
    app.terminate()
    let relaunched = try launch("C", theme: theme)
    XCTAssertTrue(
      relaunched.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    let restored = relaunched.textViews[identifier]
    XCTAssertTrue(restored.waitForExistence(timeout: 10))
    XCTAssertEqual(restored.frame.minY, y, accuracy: 24)
    offsets.append(restored.frame.minY - y)
    XCTAssertLessThanOrEqual((offsets.max() ?? 0) - (offsets.min() ?? 0), 2)
    print("READING-CYCLES \(theme) anchor=\(identifier) original=\(y) differences=\(offsets)")
    screenshot("c-after-relaunch-" + theme)
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
        screenshot("selection-pauses-following-" + theme)
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
  func testTokensInComments() throws {
    let app = try launch("COMMENT")
    let response = app.textViews.matching(
      NSPredicate(format: "value == 'Trecho para conferir os comentários.'")
    ).firstMatch
    XCTAssertTrue(response.waitForExistence(timeout: 10))
    response.tap()
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.25)).press(forDuration: 1)
    let comment = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'Comentar'")
    ).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["Comentário"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Veja @docs/alternativas")
    let file = app.buttons["suggestion-docs/alternativas.md"]
    XCTAssertTrue(file.waitForExistence(timeout: 10))
    file.tap()
    editor.typeText("@explore")
    let agent = app.buttons["suggestion-explore"]
    XCTAssertTrue(agent.waitForExistence(timeout: 10))
    agent.tap()
    editor.typeText("$conversation-check")
    let skill = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'suggestion-' AND label CONTAINS 'conversation-check'")
    ).firstMatch
    XCTAssertTrue(skill.waitForExistence(timeout: 10))
    skill.tap()
    editor.typeText("#resumo")
    let snippet = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'suggestion-' AND label CONTAINS '#resumo'")
    ).firstMatch
    XCTAssertTrue(snippet.waitForExistence(timeout: 10))
    snippet.tap()
    editor.typeText("@ex")
    XCTAssertTrue(agent.waitForExistence(timeout: 10))
    screenshot("comment-tokens-panel-openchamber-dark")
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
    app.buttons["Concluir"].tap()
    app.terminate()
    let light = try launch("COMMENT", theme: "openchamber-light")
    light.buttons["draft-quotes"].tap()
    light.buttons["Editar citação"].tap()
    let restored = light.textViews["Comentário"]
    XCTAssertTrue(restored.waitForExistence(timeout: 5))
    restored.typeText(" @ex")
    XCTAssertTrue(light.buttons["suggestion-explore"].waitForExistence(timeout: 10))
    screenshot("comment-tokens-panel-openchamber-light")
    restored.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
    light.buttons["Concluir"].tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: light.navigationBars["Comentário"])
        ], timeout: 5), .completed)
    let main = light.textViews["conversation-composer"]
    main.tap()
    main.typeText("Responda só OK, sem ferramentas. @docs/infra")
    let mainFile = light.buttons["suggestion-docs/infra.md"]
    XCTAssertTrue(mainFile.waitForExistence(timeout: 10))
    mainFile.tap()
    light.buttons["Enviar mensagem"].tap()
    waitValue(main, "")
    let bubble = light.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS 'Veja @docs/alternativas.md @Explore $conversation-check #resumo'")
    ).firstMatch
    XCTAssertTrue(bubble.waitForExistence(timeout: 15))
    screenshot("comment-sent-openchamber-light")
    light.terminate()
    let dark = try launch("COMMENT", theme: "openchamber-dark")
    XCTAssertTrue(
      dark.staticTexts.matching(
        NSPredicate(
          format: "label CONTAINS 'Veja @docs/alternativas.md @Explore $conversation-check #resumo'"
        )
      ).firstMatch.waitForExistence(timeout: 10))
    screenshot("comment-sent-openchamber-dark")
  }
  func testStickyBubbleOverCode() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = try launch("C", theme: theme)
      if app.buttons["Ir para o fim"].exists { app.buttons["Ir para o fim"].tap() }
      let transcript = app.collectionViews["conversation-transcript"]
      let cutoff = transcript.frame.minY + 130
      let beneathHeader = NSPredicate { _, _ in
        // One immutable accessibility snapshot avoids resolving a recycled TextKit
        // element again between exists/frame queries while the tail is measuring.
        guard let snapshot = try? app.snapshot() else { return false }
        return self.codeUnderHeader(snapshot, cutoff: cutoff)
      }
      XCTAssertEqual(
        XCTWaiter.wait(for: [expectation(for: beneathHeader, evaluatedWith: app)], timeout: 15),
        .completed)
      screenshot("c-sticky-code-" + theme)
    }
  }
}
