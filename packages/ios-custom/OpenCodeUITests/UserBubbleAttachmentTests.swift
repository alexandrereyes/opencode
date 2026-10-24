import XCTest
import UIKit

@MainActor final class UserBubbleAttachmentTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }

  private func launch(_ role: String, collapsing: Bool = true) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_TEST_" + role]),
      "-OpenCodeCollapsibleUserMessages", collapsing ? "YES" : "NO",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 20), .completed)
  }
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func message(_ role: String) throws -> String {
    try XCTUnwrap(environment["OPENCODE_TEST_" + role + "_MESSAGE"])
  }

  func testAttachmentsAndContextFollowSourceWhenCollapsedExpandedAndDisabled() throws {
    let twoLines = UIFontMetrics(forTextStyle: .body).scaledValue(for: 22.5) * 2
    for placement in ["LIST", "PINNED"] {
      for kind in ["IMAGE", "FILE", "QUOTE", "PLAIN", "MIXED"] {
        let role = "REVIEW_" + kind + "_" + placement
        let id = try message(role)
        let app = try launch(role)
        let toggle = app.buttons["user-prompt-toggle-" + id]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "Recolhido")
        let prompt = app.scrollViews["user-prompt-" + id]
        let text = prompt.staticTexts.firstMatch
        XCTAssertTrue(text.label.contains("Linha 12:"))
        XCTAssertEqual(prompt.frame.height, ceil(twoLines), accuracy: 1)
        if placement == "LIST" {
          XCTAssertGreaterThan(prompt.frame.minY, app.collectionViews["conversation-transcript"].frame.minY + 20)
        }
        try assertAttachments(app, kind: kind, id: id, collapsed: true)
        shot(app, "collapsed-" + role.lowercased())
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "collapsed-ax-" + role.lowercased()
        tree.lifetime = .keepAlways
        add(tree)
        toggle.tap()
        wait(NSPredicate(format: "value == 'Expandido'"), on: toggle)
        try assertAttachments(app, kind: kind, id: id, collapsed: false)
        if kind == "IMAGE" && placement == "LIST" {
          app.buttons["feed-image-captura-sintetica-com-nome-muito-longo.png"].tap()
          XCTAssertTrue(app.navigationBars["captura-sintetica-com-nome-muito-longo.png"].waitForExistence(timeout: 10))
          shot(app, "full-image-" + role.lowercased())
          app.buttons["Fechar"].tap()
          XCTAssertEqual(toggle.value as? String, "Expandido")
        }
        XCTAssertGreaterThan(prompt.frame.height, twoLines)
        shot(app, "expanded-" + role.lowercased())
        if ["QUOTE", "MIXED"].contains(kind) {
          let quote = app.buttons["user-context-quote-" + id + "-quote-0"]
          let original = quote.frame.height
          quote.tap()
          XCTAssertGreaterThan(quote.frame.height, original)
          XCTAssertTrue(quote.label.contains("Trecho citado 8."))
          shot(app, "full-quote-" + role.lowercased())
          quote.tap()
        }
        toggle.tap()
        wait(NSPredicate(format: "value == 'Recolhido'"), on: toggle)
        try assertAttachments(app, kind: kind, id: id, collapsed: true)
        app.terminate()

        let disabled = try launch(role, collapsing: false)
        XCTAssertFalse(disabled.buttons["user-prompt-toggle-" + id].exists)
        try assertAttachments(disabled, kind: kind, id: id, collapsed: false)
        XCTAssertGreaterThan(disabled.scrollViews["user-prompt-" + id].frame.height, twoLines)
        shot(disabled, "disabled-" + role.lowercased())
        disabled.terminate()
      }
    }
  }

  private func assertAttachments(_ app: XCUIApplication, kind: String, id: String, collapsed: Bool) throws {
    if ["IMAGE", "MIXED"].contains(kind) && collapsed {
      XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'feed-image-'")).firstMatch.exists)
    }
    if ["IMAGE", "MIXED"].contains(kind) && !collapsed {
      let image = app.buttons["feed-image-captura-sintetica-com-nome-muito-longo.png"]
      XCTAssertTrue(image.waitForExistence(timeout: 15))
      XCTAssertEqual(image.frame.width, 48, accuracy: 1)
      XCTAssertEqual(image.frame.height, 48, accuracy: 1)
      XCTAssertTrue(image.label.contains("imagem anexada"))
      XCTAssertFalse(app.staticTexts["captura-sintetica-com-nome-muito-longo.png"].exists)
    }
    if ["FILE", "MIXED"].contains(kind) {
      let file = app.descendants(matching: .any)["user-file-documento-sintetico-com-nome-muito-longo.txt"]
      XCTAssertTrue(file.exists)
      XCTAssertLessThanOrEqual(file.frame.width, 180)
      XCTAssertLessThanOrEqual(file.frame.height, 25)
      XCTAssertEqual(file.label, "documento-sintetico-com-nome-muito-longo.txt")
      XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "user-file-documento-sintetico-com-nome-muito-longo.txt").count, 1)
      XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'documento-sintetico-com-nome-muito-longo.txt'")).count, 1)
    }
    if ["QUOTE", "MIXED"].contains(kind) {
      let summary = app.buttons["user-context-summary-" + id + "-quote-0"]
      let quote = app.buttons["user-context-quote-" + id + "-quote-0"]
      // A folded bubble with prompt text hides its quotes and file comments entirely.
      XCTAssertFalse(summary.exists)
      XCTAssertEqual(quote.exists, !collapsed)
      if collapsed {
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'user-context-'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Trecho citado 1.'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Comentário de arquivo preservado."].exists)
      } else {
        XCTAssertTrue(quote.label.contains("Trecho citado 8."))
        XCTAssertTrue(app.staticTexts["Comentário da citação preservado."].exists)
        XCTAssertTrue(app.staticTexts["Comentário de arquivo preservado."].exists)
      }
    }
  }

  func testCaptureAttachmentPresentation() throws {
    for placement in ["LIST", "PINNED"] {
      for kind in ["IMAGE", "FILE", "QUOTE", "PLAIN", "MIXED"] {
        let role = "REVIEW_" + kind + "_" + placement
        let app = try launch(role)
        XCTAssertTrue(app.buttons["user-prompt-toggle-" + (try message(role))].waitForExistence(timeout: 15))
        shot(app, "collapsed-" + role.lowercased())
        app.terminate()
      }
    }
  }
}
