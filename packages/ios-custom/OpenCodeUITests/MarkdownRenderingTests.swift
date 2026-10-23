import XCTest
import UIKit

@MainActor final class MarkdownRenderingTests: XCTestCase {
  private var visibleTop: CGFloat = 240
  private var visibleBottom: CGFloat = 720
  func testDocumentDark() throws { try document("openchamber-dark") }
  func testDocumentLight() throws { try document("openchamber-light") }

  private func document(_ theme: String) throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
    visibleTop = app.buttons["Voltar"].firstMatch.frame.maxY + 132
    visibleBottom = app.textViews["conversation-composer"].frame.minY - 20
    let title = app.textViews.matching(NSPredicate(format: "value == %@", "✨ Formatação no OpenChamber")).firstMatch
    reveal(title, transcript: transcript)
    capture(app, "native-\(theme)-section-00")
    for section in 1...16 {
      let heading = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "\(section). ")).firstMatch
      reveal(heading, transcript: transcript)
      capture(app, String(format: "native-%@-section-%02d", theme, section))
      if section == 5 {
        let copy = app.buttons["Copiar tabela"].firstMatch
        reveal(copy, transcript: transcript)
        copy.tap()
        app.buttons["Copiar CSV"].tap()
        XCTAssertTrue(app.staticTexts["Tabela copiada"].waitForExistence(timeout: 5))
      }
      if section == 6 {
        let wrap = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'markdown-code-wrap-'")).firstMatch
        reveal(wrap, transcript: transcript)
        let previous = wrap.value as? String
        wrap.tap()
        XCTAssertNotEqual(wrap.value as? String, previous)
        wrap.tap()
        let copy = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'markdown-code-copy-'")).firstMatch
        copy.tap()
        XCTAssertTrue(app.staticTexts["Código copiado"].waitForExistence(timeout: 5))
        for (index, name) in ["JavaScript", "JSON", "Terminal", "Swift", "Python", "Texto sem destaque de linguagem", "Linha longa e linguagem desconhecida"].enumerated() {
          let language = app.textViews.matching(NSPredicate(format: "value == %@", name)).firstMatch
          reveal(language, transcript: transcript)
          capture(app, "native-\(theme)-code-\(index)")
        }
      }
      if section == 11 {
        let reference = app.textViews.matching(NSPredicate(format: "value BEGINSWITH 'Uma afirmação com uma nota explicativa'")).firstMatch
        reveal(reference, transcript: transcript, align: true)
        let prefix = ("Uma afirmação com uma nota explicativa" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 16)]).width
        reference.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: prefix + 3, dy: 8)).tap()
        XCTAssertTrue(app.navigationBars["Nota de rodapé"].waitForExistence(timeout: 10))
        capture(app, "native-\(theme)-footnote-sheet")
        app.buttons["Fechar"].tap()
      }
      if section == 13 {
        transcript.swipeUp(velocity: .slow)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        reveal(app.webViews.firstMatch, transcript: transcript)
        // A cold simulator may spend several seconds launching WebKit's processes.
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Receber conteúdo"].firstMatch.waitForExistence(timeout: 60))
        capture(app, "native-\(theme)-mermaid")
        let format = app.buttons["Formato do diagrama"].firstMatch
        reveal(format, transcript: transcript)
        format.tap()
        app.buttons["Mostrar diagrama em texto"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Receber conteúdo'")).firstMatch.waitForExistence(timeout: 15))
        capture(app, "native-\(theme)-mermaid-ascii")
        format.tap()
        app.buttons["Mostrar diagrama"].tap()
      }
      if section == 14 {
        let details = app.buttons["Ver os detalhes da revisão"].firstMatch
        reveal(details, transcript: transcript)
        XCTAssertEqual(details.value as? String, "Recolhido")
        details.tap()
        XCTAssertEqual(details.value as? String, "Expandido")
        capture(app, "native-\(theme)-details-expanded")
      }
    }
    let notes = app.staticTexts["Notas"].firstMatch
    reveal(notes, transcript: transcript, align: false)
    capture(app, "native-\(theme)-footnotes")
  }

  private func reveal(_ element: XCUIElement, transcript: XCUIElement, align: Bool = false) {
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      let frame = element.exists ? element.frame : .zero
      if element.exists && element.isHittable && (!align || frame.minY >= 230 && frame.minY <= visibleBottom - 120) { return }
      let above = frame.height > 0 && (align ? frame.minY < 230 : frame.midY < transcript.frame.minY + 100)
      let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.45 : 0.78))
      let end = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.78 : 0.45))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
    }
    XCTFail("Elemento de Markdown não ficou visível: \(element.debugDescription)")
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
