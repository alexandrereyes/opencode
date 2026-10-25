import XCTest

/// Read aloud against the sandbox's real `custom.speech` (Gemini TTS through the AI Gateway; the sandbox caches each
/// piece). Run through `script/test-file-viewer.py`.
@MainActor final class FileReadAloudTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  override func record(_ issue: XCTIssue) {
    var issue = issue
    issue.add(XCTAttachment(screenshot: MainActor.assumeIsolated { XCUIScreen.main.screenshot() }))
    super.record(issue)
  }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "read-aloud-" + name + "-" + (theme.hasSuffix("light") ? "claro" : "escuro")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func expect(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval, _ message: String) {
    let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed, message)
  }
  /// Seconds of the visible `m:ss / m:ss`: the pill's time is inside its expand button (value `m:ss de m:ss`).
  private func times(_ app: XCUIApplication) -> (elapsed: Int, total: Int) {
    let expand = app.buttons["read-aloud-expand"]
    let text = expand.exists ? (expand.value as? String ?? "") : app.staticTexts["read-aloud-time"].label
    let parts = text.components(separatedBy: text.contains(" / ") ? " / " : " de ").map { $0.split(separator: ":").compactMap { Int($0) } }
    func seconds(_ value: [Int]) -> Int { value.reduce(0) { $0 * 60 + $1 } }
    return (seconds(parts.first ?? []), seconds(parts.last ?? []))
  }
  private func openDocument(_ app: XCUIApplication) {
    let label = "Abrir doc LEITURA"
    let link = app.descendants(matching: .any).matching(NSPredicate(format: "elementType != %d AND (value CONTAINS %@ OR label CONTAINS %@)",
      XCUIElement.ElementType.navigationBar.rawValue, label, label)).firstMatch
    XCTAssertTrue(link.waitForExistence(timeout: 25), label)
    link.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 10)).tap()
    XCTAssertTrue(app.navigationBars["f-leitura.md"].waitForExistence(timeout: 20))
  }
  private func siblingArrowsReachable(_ app: XCUIApplication, _ message: String) {
    for id in ["file-previous", "file-next"] {
      XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 15), id + " " + message)
      XCTAssertTrue(app.buttons[id].isHittable, id + " " + message)
    }
  }

  func testPillPlaysPausesExpandsSeeksChangesSpeedAndStopsOnClose() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_VIEWER_LINK_DOC_LEITURA"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    openDocument(app)

    let pill = app.otherElements["read-aloud-pill"]
    let panel = app.otherElements["read-aloud-panel"]
    let play = app.buttons["read-aloud-play"]
    let expand = app.buttons["read-aloud-expand"]
    let rate = app.buttons["read-aloud-rate"]
    XCTAssertTrue(pill.waitForExistence(timeout: 20))
    XCTAssertEqual(play.label, "Ouvir documento")
    XCTAssertEqual(times(app).elapsed, 0)
    // About 3,000 speakable characters at ~12 per second, estimated before any audio.
    XCTAssertTrue((150...420).contains(times(app).total), "estimated total \(times(app).total)")
    let opened = times(app).total
    print("READ_ALOUD_TOTAL opened \(opened)")
    siblingArrowsReachable(app, "with the pill")
    screenshot("recolhida-parada")

    play.tap()
    // The run's first piece numbers the run, so it is always generated: a spinner first, then pause.
    if play.label.hasPrefix("Gerando") { screenshot("recolhida-carregando") }
    expect(play, "label == %@", "Pausar leitura", timeout: 45, "first piece playing")
    expect(expand, "NOT (value BEGINSWITH %@)", "0:00 ", timeout: 15, "elapsed time advances")
    screenshot("recolhida-tocando")
    let playing = times(app).total
    print("READ_ALOUD_TOTAL playing \(playing)")

    play.tap()
    expect(play, "label == %@", "Ouvir documento", timeout: 5, "paused")
    let paused = times(app)
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(times(app).elapsed, paused.elapsed, "a paused reading keeps its place")

    // An earlier run may have left another remembered speed.
    for _ in 0..<2 where rate.value as? String != "1×" { rate.tap() }
    expect(rate, "value == %@", "1×", timeout: 3, "speed starts at 1×")
    for expected in ["1,5×", "2×", "1×", "1,5×"] {
      rate.tap()
      expect(rate, "value == %@", expected, timeout: 3, "speed \(expected)")
    }

    // The pill's time opens the full player; the sibling arrows stay reachable over it.
    expand.tap()
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertFalse(pill.exists)
    siblingArrowsReachable(app, "with the full player")
    let progress = app.sliders["read-aloud-progress"]
    XCTAssertTrue(progress.exists)
    screenshot("expandida-pausada")

    progress.adjust(toNormalizedSliderPosition: 0.6)
    let target = times(app)
    XCTAssertGreaterThan(Double(target.elapsed), Double(target.total) * 0.45, "seeked to \(target.elapsed) of \(target.total)")
    play.tap()
    if play.label.hasPrefix("Gerando") { screenshot("expandida-carregando") }
    expect(play, "label == %@", "Pausar leitura", timeout: 90, "playing after the seek")
    // Real durations replace the estimate as pieces arrive, so compare places in the document, not seconds.
    let resumed = times(app)
    XCTAssertEqual(Double(resumed.elapsed) / Double(resumed.total), Double(target.elapsed) / Double(target.total), accuracy: 0.12)
    screenshot("expandida-tocando")
    let settled = times(app).total
    print("READ_ALOUD_TOTAL after-seek \(settled)")
    // Measured pieces move the estimate toward the real length without swinging it.
    XCTAssertEqual(Double(playing), Double(settled), accuracy: Double(settled) * 0.2, "total while playing")
    XCTAssertEqual(Double(opened), Double(settled), accuracy: Double(settled) * 0.3, "total when opened")

    app.buttons["read-aloud-collapse"].tap()
    XCTAssertTrue(pill.waitForExistence(timeout: 5))
    XCTAssertFalse(panel.exists)
    XCTAssertEqual(play.label, "Pausar leitura", "collapsing keeps playing")

    // The source view keeps the same reading.
    app.buttons["file-markdown-source"].tap()
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS '## Como usar'")).firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(pill.exists)
    XCTAssertEqual(play.label, "Pausar leitura")
    screenshot("fonte-tocando")
    app.buttons["file-markdown-source"].tap()

    // Closing ends the reading; reopening shows it paused where it stopped, with the remembered speed.
    let stopped = times(app)
    app.navigationBars["f-leitura.md"].buttons["Fechar"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    openDocument(app)
    XCTAssertTrue(pill.waitForExistence(timeout: 20))
    XCTAssertEqual(play.label, "Ouvir documento")
    expect(expand, "NOT (value BEGINSWITH %@)", "0:00 ", timeout: 10, "reopened at the saved place")
    XCTAssertEqual(Double(times(app).elapsed), Double(stopped.elapsed), accuracy: 2, "the time it was left at")
    XCTAssertEqual(rate.value as? String, "1,5×")
    rate.tap()
    rate.tap()
    expect(rate, "value == %@", "1×", timeout: 3, "speed back to 1×")
    // Start over clears the saved place for the next test.
    expand.tap()
    app.buttons["read-aloud-restart"].tap()
    XCTAssertEqual(times(app).elapsed, 0)
    XCTAssertFalse(app.buttons["read-aloud-restart"].waitForExistence(timeout: 2))
    app.terminate()
  }

  func testReopensPausedWhereItStoppedAndStartsOver() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_VIEWER_LINK_DOC_LEITURA"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    openDocument(app)
    let play = app.buttons["read-aloud-play"]
    let expand = app.buttons["read-aloud-expand"]
    XCTAssertTrue(app.otherElements["read-aloud-pill"].waitForExistence(timeout: 20))
    expect(expand, "value BEGINSWITH %@", "0:00 ", timeout: 10, "starts from the top")
    play.tap()
    expect(play, "label == %@", "Pausar leitura", timeout: 45, "playing")
    let deadline = Date.now.addingTimeInterval(20)
    while times(app).elapsed < 5, Date.now < deadline { Thread.sleep(forTimeInterval: 0.2) }
    XCTAssertGreaterThanOrEqual(times(app).elapsed, 5, "a few seconds in")
    // Closing while playing saves the place too.
    app.navigationBars["f-leitura.md"].buttons["Fechar"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    openDocument(app)
    XCTAssertTrue(app.otherElements["read-aloud-pill"].waitForExistence(timeout: 20))
    expect(expand, "NOT (value BEGINSWITH %@)", "0:00 ", timeout: 10, "a place is shown")
    let reopened = times(app).elapsed
    XCTAssertTrue((5...9).contains(reopened), "reopened at \(reopened) s")
    XCTAssertEqual(play.label, "Ouvir documento", "reopening does not play by itself")
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(times(app).elapsed, reopened)
    screenshot("reaberta-na-posicao")
    expand.tap()
    let restart = app.buttons["read-aloud-restart"]
    XCTAssertTrue(restart.waitForExistence(timeout: 5))
    screenshot("expandida-recomecar")
    restart.tap()
    XCTAssertEqual(times(app).elapsed, 0)
    XCTAssertFalse(restart.waitForExistence(timeout: 2))
    // Started over: the next opening is at the top again.
    app.navigationBars["f-leitura.md"].buttons["Fechar"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    openDocument(app)
    XCTAssertTrue(app.otherElements["read-aloud-pill"].waitForExistence(timeout: 20))
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(times(app).elapsed, 0)
    app.terminate()
  }
}
