import XCTest
import UIKit

@MainActor final class MarkdownRenderingTests: XCTestCase {
  private let app = XCUIApplication()
  func testDocumentDark() throws { try document("openchamber-dark") }
  func testDocumentLight() throws { try document("openchamber-light") }

  private func document(_ theme: String) throws {
    continueAfterFailure = false
    app.launchArguments = ["-OpenCodeServerURL", ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
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
        // The note wraps on the narrower iPhone 14; a single-line prefix width
        // otherwise taps outside the text view instead of its inline reference.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 22.5)
        let storage = NSTextStorage(string: try XCTUnwrap(reference.value as? String), attributes: [
          .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.systemFont(ofSize: 17)),
          .paragraphStyle: paragraph,
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: reference.frame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: "Uma afirmação com uma nota explicativa".utf16.count, length: 1), actualCharacterRange: nil)
        let note = layout.boundingRect(forGlyphRange: glyphs, in: container)
        reference.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: note.midX, dy: note.midY)).tap()
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
      let viewport = app.transcriptViewport(transcript)
      // Hittable alone includes buttons overlapped by the pinned prompt/composer.
      let visible = frame.minY >= viewport.minY && frame.minY + min(40, frame.height) <= viewport.maxY
      // TextKit exposes readable headings without an AX activation point on devices.
      // Their native text rect must be visible; actual controls must also accept taps.
      if element.exists && visible && (!align || frame.minY <= viewport.maxY - 120)
        && (element.elementType == .textView || element.isHittable) { return }
      let above = frame.height > 0 && frame.minY < viewport.minY
      let distance = min(viewport.height * 0.7, max(70, abs(frame.minY - viewport.midY)))
      let start = transcript.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY + (above ? -distance / 2 : distance / 2) - transcript.frame.minY))
      let end = transcript.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY + (above ? distance / 2 : -distance / 2) - transcript.frame.minY))
      start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
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
