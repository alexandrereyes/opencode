import XCTest

/// Câmera in the composer's "+" against the offline dictation fixture's composer. The simulator has no camera:
/// `-OpenCodeCameraFixture` stands in for the system picker (`photo`) or for the access answers (`denied`,
/// `restricted`, `unavailable`); the import after it is the app's own.
@MainActor final class ComposerCameraUITests: XCTestCase {
  private let app = XCUIApplication()
  override func setUp() { continueAfterFailure = false }
  override func tearDown() async throws { app.terminate() }
  private func open(_ camera: String, extra: [String] = []) throws {
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeDictationFixture", "fake",
      "-OpenCodeCameraFixture", camera,
      "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"] + extra
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    try app.requireSandbox()
  }
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
  private var photos: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remover Foto-'")) }
  private func plus() -> XCUIElement {
    app.buttons.matching(identifier: "Adicionar").allElementsBoundByIndex.last(where: \.isHittable) ?? app.buttons["Adicionar"]
  }
  private func camera() {
    plus().tap()
    let item = app.buttons["Câmera"]
    XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
    item.tap()
  }

  func testPhotoJoinsTheDraftWithoutSendingAndCancelKeepsIt() throws {
    try open("photo")
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.tap()
    editor.typeText("Texto mantido")
    plus().tap()
    // Câmera joins the existing items, before Fotos, in the same menu.
    let items = ["Expandir compositor", "Câmera", "Fotos", "Arquivos"].map { app.buttons[$0] }
    XCTAssertTrue(items[1].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(items.allSatisfy(\.exists))
    XCTAssertEqual(items.map(\.frame.minY), items.map(\.frame.minY).sorted())
    capture("camera-menu")
    items[1].tap()
    let use = app.buttons["camera-fixture-use"]
    XCTAssertTrue(use.waitForExistence(timeout: 5))
    use.tap()
    XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertEqual(photos.count, 1)
    XCTAssertEqual(editor.value as? String, "Texto mantido")
    // Nothing was sent: the text and the photo wait in the composer, with Send available.
    XCTAssertTrue(app.buttons["composer-send"].exists)
    capture("camera-photo-attached")
    camera()
    let cancel = app.buttons["camera-fixture-cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.tap()
    XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
    XCTAssertEqual(photos.count, 1)
    XCTAssertEqual(editor.value as? String, "Texto mantido")
    // A second photo adds to the first.
    camera()
    XCTAssertTrue(use.waitForExistence(timeout: 5))
    use.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: photos)], timeout: 10), .completed)
    XCTAssertEqual(editor.value as? String, "Texto mantido")
  }

  func testDeniedRestrictedAndUnavailableExplainAndKeepTheDraft() throws {
    for (mode, title, buttons) in [("denied", "Permita a câmera", ["Abrir Ajustes", "Cancelar"]),
      ("restricted", "Câmera restrita", ["OK"]), ("unavailable", "Câmera indisponível", ["OK"])] {
      try open(mode)
      let editor = app.textViews["conversation-composer"]
      XCTAssertTrue(editor.waitForExistence(timeout: 10))
      editor.tap()
      editor.typeText("Rascunho")
      camera()
      let alert = app.alerts[title]
      XCTAssertTrue(alert.waitForExistence(timeout: 5), "\(mode): \(app.debugDescription)")
      for button in buttons { XCTAssertTrue(alert.buttons[button].exists, "\(mode): \(button)") }
      capture("camera-" + mode)
      alert.buttons[buttons.last!].tap()
      XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
      XCTAssertFalse(app.buttons["camera-fixture-use"].exists)
      XCTAssertEqual(editor.value as? String, "Rascunho")
      XCTAssertEqual(photos.count, 0)
      app.terminate()
    }
  }

  /// The comment sheet and the expanded composer offer it where they offer Fotos, each presenting the camera once.
  func testCommentAndExpandedComposerTakeAPhoto() throws {
    try open("photo", extra: ["-OpenCodeDictationComment"])
    let comment = app.textViews["comment-composer"]
    XCTAssertTrue(comment.waitForExistence(timeout: 10))
    camera()
    let use = app.buttons["camera-fixture-use"]
    XCTAssertTrue(use.waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons.matching(identifier: "camera-fixture-use").count, 1)
    use.tap()
    XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(comment.exists, "the comment sheet stays open")
    capture("camera-comment")
    app.navigationBars["Comentário"].buttons["Cancelar"].tap()
    XCTAssertTrue(comment.waitForNonExistence(timeout: 5))
    plus().tap()
    app.buttons["Expandir compositor"].tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForExistence(timeout: 5))
    camera()
    XCTAssertTrue(use.waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons.matching(identifier: "camera-fixture-use").count, 1)
    use.tap()
    XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.buttons["Recolher"].exists, "the expanded composer stays open")
    capture("camera-expanded")
    app.buttons["Recolher"].tap()
    XCTAssertTrue(app.buttons["Recolher"].waitForNonExistence(timeout: 5))
    XCTAssertEqual(photos.count, 1)
  }
}
