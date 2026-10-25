import XCTest

/// Android Emulator viewer (layout 3B) against a real emulator registered in the sandbox's hub by
/// `script/test-resources-android.py`, which opens a contact form first and watches the emulator over adb to check
/// what these inputs did (typed text, Início, Recentes, Voltar).
@MainActor final class AndroidEmulatorViewerTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "android-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testWatchTakeControlTypeNavigateAndGiveBack() throws {
    let id = try XCTUnwrap(environment["OPENCODE_TEST_RESOURCE"])
    let text = try XCTUnwrap(environment["OPENCODE_TEST_ANDROID_TEXT"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenResource", id]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }

    // Watching: the live frame, the pill under "Assumir controle", its buttons disabled until control is taken.
    let frame = app.images["resource-frame"]
    XCTAssertTrue(frame.waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' ms'")).firstMatch.waitForExistence(timeout: 15))
    let home = app.buttons["resource-android-home"]
    XCTAssertTrue(home.exists)
    XCTAssertFalse(home.isEnabled, "navigation needs control")
    XCTAssertFalse(app.otherElements["resource-tools"].exists, "Android has no side tool column")
    XCTAssertTrue(app.buttons["resource-take"].frame.maxY < home.frame.minY, "the pill sits under Assumir controle")
    screenshot("watching")

    // The status pill's menu lists the stream's measurements (frame age, decode, round trip, rate).
    app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' ms'")).firstMatch.press(forDuration: 1)
    let age = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Atraso do quadro na tela'"))
      .firstMatch
    XCTAssertTrue(age.waitForExistence(timeout: 5), "the status menu lists the frame age")
    screenshot("telemetry")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
    XCTAssertTrue(age.waitForNonExistence(timeout: 5), "the status menu closed")
    XCTAssertTrue(app.buttons["resource-take"].waitForExistence(timeout: 5))

    // In control the controls hide and the pill floats; drag it out of the way and it stays there.
    app.buttons["resource-take"].tap()
    XCTAssertTrue(app.buttons["resource-control-pill"].waitForExistence(timeout: 10))
    let floating = app.buttons["resource-android-home"]
    XCTAssertTrue(floating.waitForExistence(timeout: 5))
    XCTAssertTrue(floating.isEnabled)
    // The position is remembered across launches, so move it to the other half of the screen from wherever it is.
    let before = floating.frame
    let upper = before.midY < frame.frame.midY
    floating.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
      forDuration: 0.15, thenDragTo: frame.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: upper ? 0.85 : 0.12)))
    XCTAssertGreaterThan(abs(floating.frame.midY - before.midY), 200, "the floating pill moved")
    screenshot("control-moved")

    // Touch the contact form's first field (`OPENCODE_TEST_ANDROID_TAP`, normalized in the frame) and type with
    // the iPhone keyboard: accents go through the emulator clipboard, ASCII through `input text`.
    let tap = (environment["OPENCODE_TEST_ANDROID_TAP"] ?? "0.5,0.595").split(separator: ",").compactMap { Double($0) }
    frame.coordinate(withNormalizedOffset: CGVector(dx: tap[0], dy: tap[1])).tap()
    app.buttons["resource-android-keyboard"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.textFields["resource-keyboard"].typeText(text)
    sleep(2)
    screenshot("typed")
    app.buttons["resource-android-keyboard"].tap()

    app.buttons["resource-android-home"].tap()
    sleep(2)
    screenshot("home")
    app.buttons["resource-android-recents"].tap()
    sleep(2)
    screenshot("recents")
    app.buttons["resource-android-back"].tap()
    sleep(2)

    // Controls back: the pill returns under "Devolver controle".
    app.buttons["resource-handle"].tap()
    let giveBack = app.buttons["resource-give-back"]
    XCTAssertTrue(giveBack.waitForExistence(timeout: 5))
    XCTAssertTrue(giveBack.frame.maxY < app.buttons["resource-android-home"].frame.minY)
    screenshot("control-controls")
    giveBack.tap()
    XCTAssertTrue(app.buttons["resource-take"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["resource-android-home"].isEnabled)
  }
}
