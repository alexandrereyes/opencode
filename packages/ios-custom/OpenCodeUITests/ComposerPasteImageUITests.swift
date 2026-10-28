import UIKit
import UniformTypeIdentifiers
import XCTest

/// Needs `script/test-paste-image.py`: an owned conversation with one response, in an isolated sandbox. The test
/// runner puts images on the pasteboard like another app would; the script then checks the sent messages' files.
@MainActor final class ComposerPasteImageUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  override func setUp() { continueAfterFailure = false }
  private func launch() throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
                           "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_PASTE_SESSION"])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func copyImages(_ colors: [UIColor]) {
    UIPasteboard.general.items = colors.map { color in
      [UTType.png.identifier: UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).pngData { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
      }]
    }
  }
  private func attachments(_ app: XCUIApplication) -> XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remover Imagem-'"))
  }
  private func pasteFromMenu(_ app: XCUIApplication, into editor: XCUIElement) {
    editor.press(forDuration: 1.2)
    let paste = app.menuItems["Colar"].exists ? app.menuItems["Colar"]
      : app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Colar'")).firstMatch
    XCTAssertTrue(paste.waitForExistence(timeout: 5), "Colar should be offered for an image")
    paste.tap()
  }

  func testPasteMenuAndCommandVAddImagesAsAttachmentsAndSend() throws {
    let app = try launch()
    defer { app.terminate() }
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 20))
    editor.tap()
    editor.typeText("Imagens coladas:")
    // Two images through the edit menu's Colar.
    copyImages([.systemRed, .systemBlue])
    pasteFromMenu(app, into: editor)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: attachments(app))], timeout: 15), .completed)
    shot("paste-menu-two-images")
    // One more through ⌘V on a hardware keyboard.
    copyImages([.systemGreen])
    editor.typeKey("v", modifierFlags: .command)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 3"), evaluatedWith: attachments(app))], timeout: 15), .completed)
    XCTAssertEqual(editor.value as? String, "Imagens coladas:")
    shot("paste-command-v")
    let send = app.buttons["composer-send"]
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)], timeout: 15), .completed)
    send.tap()
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: attachments(app))], timeout: 30), .completed)
    shot("paste-sent")
  }

  func testCommentSheetPastesAnImageAsItsAttachment() throws {
    let app = try launch()
    defer { app.terminate() }
    let source = try XCTUnwrap(environment["OPENCODE_PASTE_SOURCE"])
    let response = app.textViews["response-\(source)-\(source):text:0"]
    XCTAssertTrue(response.waitForExistence(timeout: 20))
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).press(forDuration: 1)
    let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'")).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText("Veja a imagem.")
    copyImages([.systemOrange])
    pasteFromMenu(app, into: editor)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: attachments(app))], timeout: 15), .completed)
    XCTAssertEqual(editor.value as? String, "Veja a imagem.")
    shot("paste-comment-sheet")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForExistence(timeout: 10))
    let composer = app.textViews["conversation-composer"]
    composer.tap()
    composer.typeText("Comentário com imagem colada.")
    let send = app.buttons["composer-send"]
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)], timeout: 15), .completed)
    send.tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForNonExistence(timeout: 30))
    shot("paste-comment-sent")
  }

  /// A recent copy makes the keyboard offer "Foto · Colar de …" in its suggestion bar; tapping it must add the
  /// attachment exactly like Colar.
  func testKeyboardRecentPasteSuggestionAddsTheImage() throws {
    let app = try launch()
    defer { app.terminate() }
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 20))
    copyImages([.systemPurple])
    editor.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
    let suggestion = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS[c] 'Colar de' OR label BEGINSWITH 'Foto'")).firstMatch
    _ = suggestion.waitForExistence(timeout: 5)
    shot("paste-keyboard-suggestion")
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "paste-keyboard-hierarchy-" + theme
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    // The candidate bar belongs to the keyboard's own process and is not in the app's tree; the reported keyboard
    // frame starts at the keys, and the single candidate is centered in the bar just above them.
    if suggestion.exists && suggestion.isHittable {
      suggestion.tap()
    } else {
      keyboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: keyboard.frame.width / 2, dy: -22)).tap()
    }
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: attachments(app))], timeout: 15), .completed)
    XCTAssertEqual((editor.value as? String)?.contains("\u{FFFC}"), false)
    shot("paste-keyboard-attached")
    attachments(app).firstMatch.tap()
  }
}
