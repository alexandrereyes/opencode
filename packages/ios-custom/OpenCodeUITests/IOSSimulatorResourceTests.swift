import XCTest

/// iOS Simulator viewer against a real serve-sim stream: `script/test-ios-simulator-resource.py` registers a booted
/// simulator (`OPENCODE_TEST_RESOURCE`) showing a local page (`OPENCODE_TEST_PAGE`) with a text field in its upper
/// part and a tap zone below; what the page receives is readable at `<page>/received`.
@MainActor final class IOSSimulatorResourceTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "ios-sim-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func received(_ page: String) async throws -> [String] {
    let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: page + "received")))
    return try JSONDecoder().decode([String].self, from: data)
  }

  func testWatchControlTypeRotateCaptureAndGiveBack() async throws {
    let id = try XCTUnwrap(environment["OPENCODE_TEST_RESOURCE"])
    let page = try XCTUnwrap(environment["OPENCODE_TEST_PAGE"])
    let typed = try XCTUnwrap(environment["OPENCODE_TEST_TYPED"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenResource", id]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }

    // Watching: the live frame and the simulator tools, disabled until Alexandre takes control.
    XCTAssertTrue(app.images["resource-frame"].waitForExistence(timeout: 30))
    let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ao vivo'")).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    // The shell's tool column carries one identifier; its buttons are found by label.
    for tool in ["Início", "Girar", "Teclado"] {
      XCTAssertFalse(app.buttons[tool].isEnabled, "\(tool) waits for control")
    }
    XCTAssertTrue(app.buttons["Captura de tela"].isEnabled)
    try await Task.sleep(for: .seconds(1))
    screenshot("watching")

    app.buttons["resource-take"].tap()
    let handle = app.buttons["resource-handle"]
    XCTAssertTrue(handle.waitForExistence(timeout: 10))
    let screen = app.otherElements["resource-touch"]

    // Tap the page's text field (upper part of the frame), bring up the iPhone keyboard and type: ASCII goes as
    // keys, the accent through serve-sim's paste, Return submits the page's form.
    screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    handle.tap()
    let keyboard = app.buttons["Teclado"]
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    XCTAssertTrue(keyboard.isEnabled)
    screenshot("control-tools")
    keyboard.tap()
    let field = app.textFields["resource-keyboard"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText(typed)
    try await Task.sleep(for: .seconds(2))
    screenshot("typed")
    field.typeText("\n")
    var arrived: [String] = []
    for _ in 0..<40 where !arrived.contains(typed) {
      try await Task.sleep(for: .milliseconds(500))
      arrived = try await received(page)
    }
    XCTAssertEqual(arrived.last, typed, "the page received the typed text")
    // Teclado closes the keyboard bridge. XCUITest's typing may swap the software keyboard for its hardware one,
    // so the check is the field's focus, not the on-screen keyboard.
    // The keyboard swap also moves the tools; tap once they stand still, or the tap lands on the screen.
    if !keyboard.isHittable { handle.tap() }
    var settled = CGRect.null
    while settled != keyboard.frame {
      settled = keyboard.frame
      try await Task.sleep(for: .milliseconds(600))
    }
    XCTAssertTrue(keyboard.isSelected)
    keyboard.tap()
    let unfocused = NSPredicate(format: "hasKeyboardFocus == false")
    await fulfillment(of: [expectation(for: unfocused, evaluatedWith: field)], timeout: 5)

    // Rotate: the frame turns upright in landscape; rotate back afterwards.
    if !app.buttons["Girar"].isHittable { handle.tap() }
    app.buttons["Girar"].tap()
    try await Task.sleep(for: .seconds(3))
    let frame = app.images["resource-frame"].frame
    screenshot("landscape")
    XCTAssertGreaterThan(frame.width, 0)
    if !app.buttons["Girar"].isHittable { handle.tap() }
    for _ in 0..<3 { app.buttons["Girar"].tap() }
    try await Task.sleep(for: .seconds(2))

    // Capture opens the share sheet with the full-size screenshot.
    if !app.buttons["Captura de tela"].isHittable { handle.tap() }
    app.buttons["Captura de tela"].tap()
    let share = app.otherElements["ActivityListView"]
    XCTAssertTrue(share.waitForExistence(timeout: 15), "share sheet")
    XCTAssertTrue(app.cells["Salvar Imagem"].waitForExistence(timeout: 10) || app.cells["Pré-Visualização"].exists)
    try await Task.sleep(for: .seconds(1))
    screenshot("capture")
    // The sheet pops over from the camera button; a tap outside closes it.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
    XCTAssertTrue(share.waitForNonExistence(timeout: 10))

    // Início goes to the simulator's home screen, then give control back.
    try await Task.sleep(for: .seconds(1))
    if !app.buttons["Início"].isHittable { handle.tap() }
    app.buttons["Início"].tap()
    try await Task.sleep(for: .seconds(2))
    screenshot("home")
    let giveBack = app.buttons["resource-give-back"]
    if !giveBack.exists { handle.tap() }
    XCTAssertTrue(giveBack.waitForExistence(timeout: 5))
    giveBack.tap()
    XCTAssertTrue(app.buttons["resource-take"].waitForExistence(timeout: 10))
  }
}
