import XCTest

/// The composer dictation outside its composer, in the real app against the sandbox (`-OpenCodeDictationFake`: the
/// fake microphone and engine, the fixtures' reviewer; no model and no real microphone): it goes on while the user
/// visits Sessões, another conversation and the Home Screen, with the strip and the Live Activity; another composer's
/// microphone is refused; Parar on the strip sends the text to the conversation it started in, and only there.
/// `script/test-background-dictation.py` seeds the two conversations.
@MainActor final class BackgroundDictationUITests: XCTestCase {
  private let app = XCUIApplication()
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }
  override func tearDown() async throws { app.terminate() }
  private func capture(_ name: String, screen: Bool = false) {
    let attachment = XCTAttachment(screenshot: screen ? XCUIScreen.main.screenshot() : app.screenshot())
    attachment.name = name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "dark"); attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
  private func label(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 10) -> Bool {
    XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)],
      timeout: timeout) == .completed
  }

  func testDictationGoesOnElsewhereAndItsTextLandsInItsOwnConversation() throws {
    let owner = try XCTUnwrap(environment["OPENCODE_BGD_OWNER"])
    let ownerTitle = try XCTUnwrap(environment["OPENCODE_BGD_OWNER_TITLE"])
    let otherTitle = try XCTUnwrap(environment["OPENCODE_BGD_OTHER_TITLE"])
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeDictationFake", "-OpenCodeDictationReview", "800",
      "-OpenCodeOpenSession", owner, "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    try app.requireSandbox()
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 30))
    // A tap records hands-free.
    let microphone = app.buttons["dictation-microphone"]
    XCTAssertTrue(microphone.waitForExistence(timeout: 10), app.debugDescription)
    microphone.tap()
    XCTAssertTrue(app.buttons["dictation-stop"].waitForExistence(timeout: 10), app.debugDescription)
    Thread.sleep(forTimeInterval: 1.5)
    capture("conversation-recording")

    // Back to Sessões: leaving is not Descartar; the strip shows the recording.
    app.buttons["Voltar"].firstMatch.tap()
    let strip = element("dictation-strip")
    XCTAssertTrue(strip.waitForExistence(timeout: 10), app.debugDescription)
    let title = element("dictation-strip-title")
    XCTAssertTrue(label(title, contains: "Gravando para \(ownerTitle)"), title.label)
    XCTAssertTrue(element("dictation-strip-stop").exists)
    capture("strip-sessoes")

    // Another conversation: the strip stays and its microphone is refused.
    let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", otherTitle)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
    row.tap()
    XCTAssertTrue(composer.waitForExistence(timeout: 30))
    XCTAssertTrue(strip.waitForExistence(timeout: 10))
    let otherMicrophone = app.buttons["dictation-microphone"]
    XCTAssertTrue(otherMicrophone.waitForExistence(timeout: 10))
    otherMicrophone.tap()
    XCTAssertTrue(element("dictation-strip-notice").waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.buttons["dictation-stop"].exists, "the other composer did not open a second microphone")
    capture("strip-refused")

    // The Home Screen and back: still recording (the Live Activity shows it outside the app).
    let before = element("dictation-strip-time").value as? String
    XCUIDevice.shared.press(.home)
    Thread.sleep(forTimeInterval: 3)
    capture("home-live-activity", screen: true)
    app.activate()
    XCTAssertTrue(strip.waitForExistence(timeout: 10))
    XCTAssertTrue(label(title, contains: "Gravando para"), title.label)
    XCTAssertNotEqual(element("dictation-strip-time").value as? String, before, "the recording went on in the background")

    // Parar on the strip: the text goes to its own conversation, never to this one.
    element("dictation-strip-stop").tap()
    XCTAssertTrue(label(title, contains: "Texto pronto em \(ownerTitle)", timeout: 30), title.label)
    capture("strip-ready")
    XCTAssertFalse((composer.value as? String ?? "").contains("Confira"), "the conversation on screen got nothing")
    element("dictation-strip-review").tap()
    let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Confira as sessões em andamento"),
      object: app.textViews["conversation-composer"])
    XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 20), .completed, app.debugDescription)
    XCTAssertFalse(strip.exists, "the destination is on screen: the strip goes")
    capture("owner-review")
  }
}
