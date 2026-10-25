import XCTest

@MainActor final class DictationUITests: XCTestCase {
  private let app = XCUIApplication()
  override func setUp() { continueAfterFailure = false }
  override func tearDown() async throws { app.terminate() }
  private func open(extra: [String] = []) {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeDictationFixture", "fake",
      "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"] + extra
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    XCTAssertTrue(app.buttons["dictation-microphone"].waitForExistence(timeout: 10), app.debugDescription)
  }
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
  private func assertReview() {
    XCTAssertTrue(app.buttons["Recolher"].waitForExistence(timeout: 15), app.debugDescription)
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertTrue((editor.value as? String ?? "").contains("Confira as sessões em andamento"))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    capture("after-fullscreen-review")
    editor.typeText(" Revisado.")
    XCTAssertTrue((editor.value as? String ?? "").hasSuffix(" Revisado."))
    app.buttons["Recolher"].tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForNonExistence(timeout: 5))
    XCTAssertTrue((app.textViews["conversation-composer"].value as? String ?? "").contains("Revisado."))
  }
  func testHoldReleaseTranscribesIntoFullscreenWithoutSending() {
    open(); capture("before-recording")
    app.buttons["dictation-microphone"].press(forDuration: 1.8)
    assertReview()
  }
  /// As in WhatsApp on iPhone: releasing a hold before one second neither transcribes nor discards; it keeps
  /// recording hands-free.
  func testSlideLeftCancelsAndShortHoldKeepsRecordingHandsFree() {
    open()
    let microphone = app.buttons["dictation-microphone"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    microphone.press(forDuration: 1.5, thenDragTo: microphone.withOffset(CGVector(dx: -150, dy: 0)))
    XCTAssertTrue(app.buttons["dictation-microphone"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Recolher"].exists)
    app.buttons["dictation-microphone"].press(forDuration: 0.6)
    XCTAssertTrue(app.buttons["dictation-stop"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["dictation-pause-resume"].exists)
    XCTAssertFalse(app.buttons["Recolher"].exists)
    app.buttons["dictation-discard"].tap()
    XCTAssertTrue(app.buttons["dictation-microphone"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Recolher"].exists)
    XCTAssertFalse((app.textViews["conversation-composer"].value as? String ?? "").contains("Confira"))
  }
  func testSlideUpLocksPausePreviewResumeAndStop() {
    open()
    let microphone = app.buttons["dictation-microphone"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    microphone.press(forDuration: 1.8, thenDragTo: microphone.withOffset(CGVector(dx: 0, dy: -120)))
    let stop = app.buttons["dictation-stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    capture("locked-waveform")
    XCTAssertFalse(app.buttons["Recolher"].exists)
    app.buttons["dictation-pause-resume"].tap()
    let preview = app.buttons["dictation-preview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: preview)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    preview.tap()
    XCTAssertEqual(preview.label, "Pausar pré-escuta")
    app.buttons["dictation-pause-resume"].tap()
    stop.tap()
    assertReview()
  }
  func testTapStartsHandsFreeAndTrashDiscards() {
    open()
    app.buttons["dictation-microphone"].tap()
    XCTAssertTrue(app.buttons["dictation-stop"].waitForExistence(timeout: 5))
    app.buttons["dictation-discard"].tap()
    XCTAssertTrue(app.buttons["dictation-microphone"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Recolher"].exists)
  }
  func testLargestAccessibilitySizeKeepsRecordingAndPreviewControlsReachable() {
    open(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    app.buttons["dictation-microphone"].tap()
    XCTAssertTrue(app.buttons["dictation-stop"].waitForExistence(timeout: 5))
    app.buttons["dictation-pause-resume"].tap()
    let seek = app.sliders["Posição da pré-escuta"]
    XCTAssertTrue(seek.waitForExistence(timeout: 5))
    let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["dictation-preview"])
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    XCTAssertGreaterThanOrEqual(seek.frame.height, 44)
    for id in ["dictation-discard", "dictation-preview", "dictation-pause-resume", "dictation-stop"] {
      let button = app.buttons[id]
      XCTAssertTrue(button.isHittable, id)
      XCTAssertGreaterThanOrEqual(button.frame.width, 44, id)
      XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
    }
    capture("largest-text-preview")
    app.buttons["dictation-discard"].tap()
  }
  func testCommentDictationLandsInTheCommentAndConcluirKeepsIt() {
    open(extra: ["-OpenCodeDictationComment"])
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let microphone = app.buttons.matching(identifier: "dictation-microphone").allElementsBoundByIndex.last(where: \.isHittable)
    XCTAssertNotNil(microphone, app.debugDescription)
    microphone?.press(forDuration: 1.8)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value CONTAINS 'Confira as sessões em andamento'"), evaluatedWith: editor)], timeout: 15), .completed)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Recolher"].exists)
    // With content the comment's main action concludes, and the compact microphone complements it.
    XCTAssertTrue(app.buttons["comment-done"].exists)
    XCTAssertTrue(app.buttons.matching(identifier: "composer-microphone").allElementsBoundByIndex.contains(where: \.isHittable))
    capture("comment-dictation-review")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["draft-quotes"].waitForExistence(timeout: 5))
    XCTAssertFalse((app.textViews["conversation-composer"].value as? String ?? "").contains("Confira"))
    app.buttons["draft-quotes"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Confira as sessões em andamento'")).firstMatch.waitForExistence(timeout: 5))
    capture("comment-dictation-committed")
  }
  private let transcript = "Confira as sessões em andamento e prepare um resumo das alterações. Não envie esta mensagem antes da minha revisão."
  /// Option A: with text the big button sends and a compact microphone beside it records with the same gesture.
  func testCompactMicrophoneBesideSendInsertsAtTheCaret() {
    open()
    XCTAssertFalse(app.buttons["composer-microphone"].exists)
    XCTAssertFalse(app.buttons["composer-send"].exists)
    capture("compact-empty")
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("Início fim")
    let compact = app.buttons["composer-microphone"]
    XCTAssertTrue(compact.waitForExistence(timeout: 5))
    XCTAssertEqual(compact.label, "Gravar áudio")
    let send = app.buttons["composer-send"]
    XCTAssertTrue(send.exists)
    XCTAssertFalse(app.buttons["dictation-microphone"].exists)
    XCTAssertLessThanOrEqual(compact.frame.maxX, send.frame.minX)
    XCTAssertEqual(compact.frame.midY, send.frame.midY, accuracy: 1)
    XCTAssertGreaterThanOrEqual(compact.frame.width, 44)
    XCTAssertGreaterThanOrEqual(compact.frame.height, 44)
    // The fixture has no models or MCPs: the control row is only the + menu.
    XCTAssertLessThanOrEqual(app.buttons["Adicionar"].frame.maxX, compact.frame.minX)
    // The caret goes to the start of the text: the transcription lands there, not at the end.
    editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 2, dy: 10)).tap()
    capture("compact-with-text")
    let center = compact.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    center.press(forDuration: 1.5, thenDragTo: center.withOffset(CGVector(dx: -150, dy: 0)))
    XCTAssertTrue(compact.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Recolher"].exists)
    XCTAssertEqual(editor.value as? String, "Início fim")
    compact.press(forDuration: 1.8)
    XCTAssertTrue(app.buttons["Recolher"].waitForExistence(timeout: 15), app.debugDescription)
    let expanded = app.textViews["conversation-composer"]
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", transcript + " Início fim"), evaluatedWith: expanded)], timeout: 5), .completed, String(describing: expanded.value))
    XCTAssertTrue(app.buttons["composer-microphone"].exists)
    capture("compact-review")
    app.buttons["Recolher"].tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForNonExistence(timeout: 5))
  }
  func testCompactMicrophoneTapIsHandsFreeAndTheAgentMovedToTheFooter() {
    open()
    let agent = app.buttons["agent-picker"]
    XCTAssertTrue(agent.exists)
    XCTAssertGreaterThan(agent.frame.minY, app.buttons["Adicionar"].frame.maxY)
    XCTAssertEqual(agent.value as? String, "build")
    agent.tap()
    XCTAssertTrue(app.navigationBars["Agente"].waitForExistence(timeout: 5))
    app.buttons["plan"].tap()
    XCTAssertTrue(app.navigationBars["Agente"].waitForNonExistence(timeout: 5))
    XCTAssertEqual(agent.value as? String, "plan")
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("Texto digitado")
    let compact = app.buttons["composer-microphone"]
    XCTAssertTrue(compact.waitForExistence(timeout: 5))
    compact.tap()
    let stop = app.buttons["dictation-stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    XCTAssertTrue(compact.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["dictation-pause-resume"].exists)
    XCTAssertFalse(app.buttons["Recolher"].exists)
    Thread.sleep(forTimeInterval: 1.2)
    capture("compact-hands-free")
    stop.tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForExistence(timeout: 15), app.debugDescription)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == %@", "Texto digitado " + transcript), evaluatedWith: app.textViews["conversation-composer"])], timeout: 5), .completed)
    XCTAssertTrue(app.buttons["agent-picker"].exists)
    app.buttons["Recolher"].tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForNonExistence(timeout: 5))
  }
  func testModelSettingsShowLocalStatusAndDeletionCanBeCancelled() {
    open()
    app.buttons["Modelo"].tap()
    XCTAssertTrue(app.navigationBars["Transcrição"].waitForExistence(timeout: 5))
    let status = app.staticTexts["transcription-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertTrue(status.label.contains("Pronto"))
    app.buttons["Apagar modelo"].tap()
    XCTAssertTrue(app.alerts["Apagar modelo de transcrição?"].waitForExistence(timeout: 5))
    app.alerts.buttons["Cancelar"].tap()
    XCTAssertTrue(status.label.contains("Pronto"))
    capture("model-settings")
  }
}
