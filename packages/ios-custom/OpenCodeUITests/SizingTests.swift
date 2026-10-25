import UIKit
import XCTest

@MainActor final class SizingTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testDefaultGeometryInBothThemes() throws { try geometry("UICTContentSizeCategoryL", label: "default") }
  func testXXXLargeGeometryInBothThemes() throws { try geometry("UICTContentSizeCategoryXXXL", label: "xxxLarge") }
  func testAccessibleGeometryInBothThemes() throws { try geometry("UICTContentSizeCategoryAccessibilityL", label: "accessibility2") }

  private func geometry(_ category: String, label: String) throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
        "-OpenCodeMCPFixture", "sizing", "-OpenCodeSizingDiagnostics", "-UIPreferredContentSizeCategoryName", category]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"]
      app.launch()
      defer { app.terminate() }
      let pill = app.buttons["conversation-mcp-pill"]
      XCTAssertTrue(pill.waitForExistence(timeout: 20))
      XCTAssertEqual(pill.frame.height, 20, accuracy: 1)
      let model = app.buttons["model-picker"]
      XCTAssertTrue(model.exists)
      XCTAssertEqual(model.value as? String, "Opus 5.5 · xhigh")
      let intrinsic = ("Opus 5.5 · xhigh" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 12)]).width
      XCTAssertGreaterThanOrEqual(model.frame.width, intrinsic - 1, "The model must fit without truncation")
      XCTAssertLessThanOrEqual(model.frame.maxX, pill.frame.minX)
      let bubble = app.descendants(matching: .any)["user-bubble-msg_mcp_user"].firstMatch
      let meta = app.descendants(matching: .any)["user-meta-msg_mcp_user"].firstMatch
      let time = app.staticTexts["user-time-msg_mcp_user"]
      let undo = app.buttons["user-revert-msg_mcp_user"]
      XCTAssertTrue(bubble.exists)
      XCTAssertTrue(meta.exists)
      XCTAssertTrue(undo.isHittable)
      let copy = app.buttons["user-copy-msg_mcp_user"]
      XCTAssertTrue(copy.isHittable)
      // The footer row and glyphs stay below the bubble. The container's accessibility frame also
      // includes the copy button's 44 pt target, which reaches 8 pt into the bubble's empty padding.
      XCTAssertGreaterThanOrEqual(undo.frame.minY, bubble.frame.maxY)
      XCTAssertGreaterThanOrEqual(time.frame.minY, bubble.frame.maxY)
      XCTAssertEqual(meta.frame.minY, copy.frame.minY, accuracy: 0.5)
      XCTAssertEqual(copy.frame.minY, undo.frame.minY - 12, accuracy: 1)
      XCTAssertEqual(copy.frame.height, 44, accuracy: 1)
      XCTAssertEqual(copy.frame.maxY, undo.frame.maxY + 8, accuracy: 1)
      XCTAssertEqual(meta.frame.maxX, bubble.frame.maxX, accuracy: 1)
      XCTAssertEqual(bubble.frame.maxX, app.frame.maxX - 16, accuracy: 1)
      let usage = app.buttons["conversation-usage"]
      XCTAssertTrue(usage.waitForExistence(timeout: 10))
      XCTAssertEqual(usage.frame.height, 40, accuracy: 1)
      XCTAssertGreaterThan(usage.frame.minY, app.buttons["model-picker"].frame.maxY)
      let composer = app.descendants(matching: .any)["composer-card"].firstMatch
      XCTAssertEqual(composer.frame.minX, 12, accuracy: 1)
      XCTAssertEqual(composer.frame.maxX, app.frame.maxX - 12, accuracy: 1)
      XCTAssertEqual(app.frame.maxY - composer.frame.maxY, 40, accuracy: 1)
      XCTAssertEqual(app.frame.maxY - usage.frame.midY, 20, accuracy: 1)
      XCTAssertTrue(app.buttons["Enviar mensagem"].exists || app.buttons["Gravar para transcrever"].exists)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "sizing-" + label + "-" + theme
      shot.lifetime = .keepAlways
      add(shot)
      // With text, the compact microphone joins Send; nothing in the control row may reach either of them.
      let editor = app.textViews["conversation-composer"]
      editor.tap()
      editor.typeText("Texto")
      let microphone = app.buttons["composer-microphone"]
      XCTAssertTrue(microphone.waitForExistence(timeout: 5))
      let send = app.buttons["composer-send"]
      XCTAssertTrue(microphone.isHittable)
      XCTAssertTrue(send.isHittable)
      XCTAssertGreaterThanOrEqual(microphone.frame.width, 44)
      XCTAssertLessThanOrEqual(microphone.frame.maxX, send.frame.minX)
      if !category.contains("Accessibility") {
        XCTAssertLessThanOrEqual(model.frame.maxX, pill.frame.minX)
        XCTAssertLessThanOrEqual(pill.frame.maxX, microphone.frame.minX)
      }
      let typed = XCTAttachment(screenshot: app.screenshot())
      typed.name = "sizing-text-" + label + "-" + theme
      typed.lifetime = .keepAlways
      add(typed)
      usage.tap()
      XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    }
  }
}
