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
      "-OpenCodeServerURL", TestSandbox.url,
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
      let step = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atividade · Ler, Agente e Editar · 5 ferramentas'")).firstMatch
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
      func openTranscriptChild() {
        let child = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Comparar alternativas Linear'")).firstMatch
        reveal(child, forward: true)
        XCTAssertTrue(child.exists && child.isHittable)
        screenshot("child-card-visible-" + theme)
        child.tap()
      }
      func openChild() {
        guard agents.exists else { openTranscriptChild(); return }
        agents.tap()
        XCTAssertTrue(app.navigationBars["Agentes e tarefas"].waitForExistence(timeout: 5))
        let child = app.buttons.matching(
          NSPredicate(format: "label BEGINSWITH 'Explore' AND label CONTAINS 'Comparar alternativas'")
        ).firstMatch
        if child.waitForExistence(timeout: 5) { child.tap(); return }
        // A background task can keep the counter visible after this child finishes.
        app.navigationBars["Agentes e tarefas"].buttons.element(boundBy: 0).tap()
        openTranscriptChild()
      }
      openChild()
      XCTAssertTrue(app.buttons["subagent-badge"].waitForExistence(timeout: 10))
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
      screenshot("parent-edge-swipe-" + theme)
      XCTAssertTrue(app.buttons["subagent-badge"].waitForNonExistence(timeout: 5))
      // A child opened from the agents screen returns to it first.
      let agentsBar = app.navigationBars["Agentes e tarefas"]
      if agentsBar.waitForExistence(timeout: 2) { agentsBar.buttons.element(boundBy: 0).tap() }
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
      XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 10))
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
        // The transcript lays out only the rows near the screen: scroll until the answer's last paragraph is one.
        let response = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Recomendo o'"))
          .firstMatch
        for _ in 0..<3 where !response.exists { transcript.swipeDown(velocity: .slow) }
        for _ in 0..<4 where !response.exists { transcript.swipeUp(velocity: .slow) }
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
      for _ in 0..<8 {
        let viewport = app.transcriptViewport(transcript)
        if permit.exists && permit.frame.minY >= viewport.minY && permit.frame.maxY <= viewport.maxY
          && permit.isHittable { break }
        app.dragTranscript(transcript, viewport: viewport, delta: -120)
      }
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
        "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
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
  /// Sending works like ChatGPT and Claude: the prompt rises to the top of the transcript, the answer grows
  /// below it without moving the screen, and ↓ appears once it passes the end. Calls the model once.
  func testSentPromptRisesAndTheAnswerGrowsInPlace() throws {
    let app = try launch("SEND", theme: environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    let transcript = app.collectionViews["conversation-transcript"]
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Escreva 30 linhas numeradas, uma frase curta sobre o mar em cada. Sem introdução.")
    let send = app.buttons["composer-send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    send.tap()
    // The sent prompt rises to the top of the transcript.
    // Its text sits the bubble's padding (8 + 12 points) below the transcript's top edge.
    let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Escreva 30 linhas numeradas'")).firstMatch
    let risen = expectation(for: NSPredicate { _, _ in
      prompt.exists && abs(prompt.frame.minY - transcript.frame.minY - 20) <= 2
    }, evaluatedWith: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [risen], timeout: 10), .completed, "the sent prompt rises to the top")
    let top = prompt.frame.minY
    // While the answer streams (and once it ends), nothing on screen moves.
    var samples: [CGFloat] = []
    let end = app.buttons["Ir para a mais recente"]
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      samples.append(prompt.frame.minY)
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    XCTAssertTrue(end.exists, "↓ appears once the answer passes the end")
    XCTAssertGreaterThan(samples.count, 10)
    XCTAssertLessThanOrEqual(samples.map { abs($0 - top) }.max() ?? 0, 0.5, "the answer grows without moving the screen")
    screenshot("send-risen-" + (environment["OPENCODE_TEST_THEME"] ?? "dark"))
  }

  /// A refresh in the middle of an answer (here, leaving the app and coming back while it streams) never
  /// leaves a gap: every sample of the answer numbers its lines from 1 without skipping. Calls the model once.
  func testStreamingAnswerHasNoGapAcrossARefresh() throws {
    let app = try launch("SEND", theme: environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Escreva 150 linhas numeradas, uma frase curta sobre o mar em cada. Sem introdução.")
    app.buttons["composer-send"].tap()
    let answer = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH '1.'"))
      .firstMatch
    XCTAssertTrue(answer.waitForExistence(timeout: 30))
    var samples: [String] = []
    func sample() { if answer.exists, let value = answer.value as? String { samples.append(value) } }
    for _ in 0..<4 { sample(); RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    XCUIDevice.shared.press(.home)
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    app.activate()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    // The answer is still running on return, so the reconnection's read lands mid-answer.
    let stop = app.buttons["Parar"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5), "the answer ended while the app was away")
    // Until the answer ends (its stop control goes away), then once more.
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline, stop.exists {
      sample()
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    sample()
    XCTAssertGreaterThan(samples.count, 6)
    for value in samples {
      let numbers = value.split(separator: "\n").compactMap { line in
        line.split(separator: ".", maxSplits: 1).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
      }
      XCTAssertEqual(numbers, Array(1..<(numbers.count + 1)), "no gap in: \(value.suffix(300))")
    }
    screenshot("stream-refresh-" + (environment["OPENCODE_TEST_THEME"] ?? "dark"))
  }

  /// Leaving a conversation mid-answer and coming back shows everything streamed meanwhile and keeps streaming:
  /// the retained conversation recorded the stream off screen. Calls the model once.
  func testReturningMidAnswerShowsWhatStreamedAwayAndContinuesLive() throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_SEND"])
    let app = try launch("SEND", theme: environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    let answer = try ask(app)
    let before = numbers(answer.value as? String ?? "")
    app.buttons["Voltar"].tap()
    RunLoop.current.run(until: Date().addingTimeInterval(4))
    let row = app.buttons["session-row-" + session]
    app.revealSessionRow(row)
    row.tap()
    XCTAssertTrue(answer.waitForExistence(timeout: 10))
    let stop = app.buttons["Parar"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5), "the answer ended while away")
    let returned = numbers(answer.value as? String ?? "")
    XCTAssertGreaterThan(returned.count, before.count + 5, "what streamed while away is shown at once")
    let samples = sampleUntilEnd(answer, stop: stop)
    XCTAssertGreaterThan(Set(samples.map(\.count)).count, 2, "it keeps streaming live")
    for value in samples {
      let lines = numbers(value)
      XCTAssertEqual(lines, Array(1..<(lines.count + 1)), "no gap in: \(value.suffix(300))")
    }
  }

  /// A conversation opened mid-answer, its beginning streamed before the screen existed, shows the answer live
  /// from what arrives, after a marker, and the whole answer at its end. Calls the model once.
  func testOpeningMidAnswerShowsItLiveAfterAMarker() throws {
    let theme = environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"
    var app = try launch("SEND", theme: theme)
    _ = try ask(app)
    // A new process: nothing of this answer was recorded.
    app.terminate()
    app = try launch("SEND", theme: theme)
    let stop = app.buttons["Parar"]
    XCTAssertTrue(stop.waitForExistence(timeout: 10), "the answer ended before the screen opened")
    // It reopens at the saved place, above the answer.
    let end = app.buttons["Ir para a mais recente"]
    if end.waitForExistence(timeout: 5) { end.tap() }
    let partial = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH '…'"))
      .firstMatch
    XCTAssertTrue(partial.waitForExistence(timeout: 15), "the answer shows live, after the missing-start marker")
    screenshot("open-mid-answer-" + theme)
    let samples = sampleUntilEnd(partial, stop: stop).filter { $0.hasPrefix("…") }
    XCTAssertGreaterThan(Set(samples.map(\.count)).count, 2, "it streams live")
    for value in samples {
      // The first sample may hold only the end of a line.
      let lines = numbers(value)
      guard let first = lines.first else { continue }
      XCTAssertEqual(lines, Array(first..<(first + lines.count)), "no gap in: \(value.suffix(300))")
    }
    let whole = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH '1.'"))
      .firstMatch
    XCTAssertTrue(whole.waitForExistence(timeout: 15), "the end brings the beginning")
    let lines = numbers(whole.value as? String ?? "")
    XCTAssertEqual(lines, Array(1..<(lines.count + 1)))
    XCTAssertGreaterThan(lines.count, 100)
  }

  private func ask(_ app: XCUIApplication) throws -> XCUIElement {
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    // Long enough to still be streaming after leaving and coming back, or after a relaunch.
    composer.typeText("Escreva 200 linhas numeradas, cada uma com uma frase de umas quinze palavras sobre o mar. Sem introdução.")
    app.buttons["composer-send"].tap()
    let answer = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH '1.'"))
      .firstMatch
    XCTAssertTrue(answer.waitForExistence(timeout: 60))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    return answer
  }
  private func sampleUntilEnd(_ answer: XCUIElement, stop: XCUIElement) -> [String] {
    var samples: [String] = []
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline, stop.exists {
      if answer.exists, let value = answer.value as? String { samples.append(value) }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
    return samples
  }
  private func numbers(_ value: String) -> [Int] {
    value.split(separator: "\n").compactMap { line in
      line.split(separator: ".", maxSplits: 1).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
  }

  /// Hidden for more than 30 seconds while a message arrives: on return the passage on screen has not moved, the
  /// arrival is merged within seconds without the event stream noticing anything, and ↓ offers it.
  func testBackgroundArrivalKeepsThePassageAndOffersIt() throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_SEND"])
    let app = try launch("SEND", theme: environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    let transcript = app.collectionViews["conversation-transcript"]
    let reading = transcript.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'text:'")).allElementsBoundByIndex
      .last { $0.frame.minY < transcript.frame.maxY && $0.frame.maxY > transcript.frame.minY }
    let anchor = try XCTUnwrap(reading)
    let before = anchor.frame
    XCUIDevice.shared.press(.home)
    // A shell command posts a visible message without calling a model.
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    var request = URLRequest(url: URL(string: TestSandbox.url + "/api/session/" + session + "/shell")!)
    request.httpMethod = "POST"
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"command":"echo novidade-de-fundo"}"#.utf8)
    let posted = expectation(description: "shell posted")
    URLSession.shared.dataTask(with: request) { _, response, _ in
      XCTAssertLessThan((response as? HTTPURLResponse)?.statusCode ?? 999, 300, "the shell command was accepted")
      posted.fulfill()
    }.resume()
    wait(for: [posted], timeout: 15)
    RunLoop.current.run(until: Date().addingTimeInterval(32))
    app.activate()
    let end = app.buttons["Ir para a mais recente"]
    let returned = Date()
    XCTAssertTrue(end.waitForExistence(timeout: 6), "the arrival is merged and offered by ↓")
    let merged = Date().timeIntervalSince(returned)
    XCTAssertEqual(anchor.frame.minY, before.minY, accuracy: 0.5, "the passage on screen did not move")
    screenshot("background-arrival-" + (environment["OPENCODE_TEST_THEME"] ?? "dark"))
    end.tap()
    // The arrival is a collapsed shell step at the end.
    let steps = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Atividade · Shell · 1 ferramenta'"))
    XCTAssertTrue(steps.firstMatch.waitForExistence(timeout: 5))
    let step = try XCTUnwrap(steps.allElementsBoundByIndex.last)
    XCTAssertLessThanOrEqual(step.frame.maxY, transcript.frame.maxY)
    let attachment = XCTAttachment(string: String(format: "merged %.1f s after returning", merged))
    attachment.lifetime = .keepAlways
    add(attachment)
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
