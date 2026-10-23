import XCTest

@MainActor final class DictationUITests: XCTestCase {
  private let app = XCUIApplication()
  override func setUp() { continueAfterFailure = false }
  override func tearDown() async throws { app.terminate() }
  private func open(extra: [String] = []) {
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeDictationFixture", "fake",
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
  func testSlideLeftCancelsAndShortHoldDiscards() {
    open()
    let microphone = app.buttons["dictation-microphone"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    microphone.press(forDuration: 1.5, thenDragTo: microphone.withOffset(CGVector(dx: -150, dy: 0)))
    XCTAssertTrue(app.buttons["dictation-microphone"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Recolher"].exists)
    app.buttons["dictation-microphone"].press(forDuration: 0.4)
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
