import AppIntents
import XCTest

@MainActor final class ReadingContinuityTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
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
    // Other sandbox suites import recent histories concurrently; old seeds can be
    // several screens below the freshly imported sessions.
    for _ in 0..<20 {
      if row.exists { break }
      app.collectionViews.firstMatch.swipeUp(velocity: .fast)
    }
    app.revealSessionRow(row)
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
    let theme = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    let app = try launch("OWN", theme: theme)
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    waitValue(editor, "")
    editor.typeText("OK")
    func keyboard() throws -> XCUIElement {
      let bounds = app.frame
      let visible = { app.keyboards.allElementsBoundByIndex.first {
        let frame = $0.frame
        return frame.height > 0 && frame.minY >= bounds.minY && frame.maxY <= bounds.maxY + 1
      } }
      XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in visible() != nil }, object: nil)], timeout: 10), .completed)
      return try XCTUnwrap(visible())
    }
    try keyboard().buttons["Return"].tap()
    waitValue(editor, "OK\n")
    // A new sentence is automatically shifted; Return must still insert a newline.
    try keyboard().buttons["Return"].tap()
    waitValue(editor, "OK\n\n")
    // Disable automatic Shift, then double-tap to lock it.
    try keyboard().buttons["shift"].tap()
    try keyboard().buttons["shift"].doubleTap()
    try keyboard().buttons["Return"].tap()
    waitValue(editor, "OK\n\n\n")
    screenshot("keyboard-caps-lock-newline-" + theme)
    // Leave Caps Lock, type prose to clear automatic capitalization, then manually Shift.
    try keyboard().buttons["shift"].tap()
    editor.typeText("ok")
    try keyboard().buttons["shift"].tap()
    try keyboard().buttons["Return"].tap()
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
    if app.buttons["Ir para a mais recente"].exists { app.buttons["Ir para a mais recente"].tap() }
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
    // Each theme has its own runner invocation and 180-second execution budget.
    for theme in environment["OPENCODE_TEST_THEME"].map({ [$0] }) ?? ["openchamber-dark"] {
      let app = try launch("A", theme: theme)
      let transcript = app.collectionViews["conversation-transcript"]
      func reveal(_ element: XCUIElement, forward: Bool = false) {
        for attempt in 0..<20 {
          let visible = app.transcriptViewport(transcript)
          let exists = element.exists
          let frame = exists ? element.frame : .zero
          if exists && element.isHittable && visible.contains(frame) { return }
          // Move only the missing distance; fixed drags can oscillate across the
          // narrow viewport between a tall pinned prompt and the composer.
          let delta = exists ? (frame.minY < visible.minY ? visible.minY - frame.minY : visible.maxY - frame.maxY)
            : ((attempt < 10) == forward ? -120.0 : 120.0)
          print("TRANSCRIPT-REVEAL attempt=\(attempt) frame=\(frame) usable=\(visible) delta=\(delta)")
          app.dragTranscript(transcript, viewport: visible, delta: delta)
        }
        screenshot("reveal-failure-" + theme)
        XCTFail("O conteúdo deve estar visível abaixo da mensagem fixada")
      }
      let step = app.buttons["Usou 5 · Ler, Agente e Editar"]
      reveal(step)
      XCTAssertTrue(step.waitForExistence(timeout: 10))
      if step.value as? String != "Expandido" { step.tap() }
      let reasoning = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reasoning-'")).firstMatch
      XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
      // Expanding the group may follow the tail; XCTest's automatic scroll can
      // place this button under the pinned user bubble instead of making it tappable.
      reveal(reasoning)
      let thought = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Vou consultar a infraestrutura e separar licença de integrações.'")).firstMatch
      if reasoning.value as? String != "Expandido" { reasoning.tap() }
      XCTAssertTrue(thought.waitForExistence(timeout: 5))
      screenshot("expanded-before-child-" + theme)
      let prompt = app.buttons["Mostrar mensagem completa"].firstMatch
      if prompt.exists && prompt.isHittable {
        prompt.tap()
        reveal(thought, forward: true)
        screenshot("expanded-prompt-before-child-" + theme)
      }
      let agents = app.buttons.matching(NSPredicate(format: "label CONTAINS 'agentes em execução'")).firstMatch
      if agents.exists {
        agents.tap()
        app.buttons.matching(
          NSPredicate(format: "label BEGINSWITH 'Explore' AND label CONTAINS 'Comparar alternativas'")
        ).firstMatch.tap()
      } else {
        // The seed's executions may have finished; the real child card remains navigable.
        let child = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Comparar alternativas Linear'")).firstMatch
        reveal(child, forward: true)
        XCTAssertTrue(child.exists && child.isHittable)
        screenshot("child-card-visible-" + theme)
        child.tap()
      }
      XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 10))
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
      screenshot("parent-edge-swipe-" + theme)
      XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForNonExistence(timeout: 5))
      reveal(step)
      XCTAssertTrue(step.waitForExistence(timeout: 10))
      XCTAssertEqual(step.value as? String, "Expandido")
      reveal(thought, forward: true)
      XCTAssertTrue(thought.exists)
      screenshot("expanded-after-child-" + theme)
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
      XCTAssertTrue(app.navigationBars["Sessões"].waitForExistence(timeout: 10))
      openFromSessions(app, title: "Conversa A — trabalhando")
      reveal(step)
      XCTAssertEqual(step.value as? String, "Expandido")
      reveal(thought, forward: true)
      XCTAssertTrue(thought.exists)
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
      if app.buttons["Ir para a mais recente"].exists { app.buttons["Ir para a mais recente"].tap() }
      let permit = app.buttons["Permitir"].firstMatch
      XCTAssertTrue(permit.waitForExistence(timeout: 5))
      XCTAssertTrue(permit.isHittable)
      XCTAssertLessThan(permit.frame.maxY, app.buttons["draft-quotes"].frame.minY)
      screenshot("b-expanded-quotes-" + theme)
      app.terminate()
    }
  }
  func testJumpToLatestWithoutUnreadStateInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
        "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "middle",
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 20))
      waitForReading(app)
      let latest = app.buttons["Ir para a mais recente"]
      XCTAssertTrue(latest.waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["Ir às novas mensagens"].exists)
      XCTAssertFalse(app.staticTexts["Novas mensagens"].exists)
      screenshot("app-history-" + theme)
      latest.tap()
      let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
      XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 20), .completed)
      screenshot("app-tapped-" + theme)
      app.terminate()
    }
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
}
