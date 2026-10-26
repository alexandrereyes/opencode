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
    // Consecutive paragraphs, headings, lists, quotations and rules form one selectable text.
    let title = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value BEGINSWITH %@", "✨ Formatação no OpenChamber")).firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    XCTAssertTrue((title.value as? String ?? "").contains("\n\n1. Destaques no texto\n\n"))
    reveal(title, transcript: transcript)
    capture(app, "native-\(theme)-section-00")
    for section in 1...16 {
      let heading = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND (value BEGINSWITH %@ OR value CONTAINS %@)",
        "\(section). ", "\n\n\(section). ")).firstMatch
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
          let language = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND (value == %@ OR value ENDSWITH %@)", name, "\n\n" + name)).firstMatch
          reveal(language, transcript: transcript)
          capture(app, "native-\(theme)-code-\(index)")
        }
      }
      if section == 11 {
        // The note paragraph is one segment of a joined text, so the fixture driver aligns that
        // segment's top at y = 240 and the note glyph is located within the paragraph alone.
        app.terminate()
        app.launchArguments += ["-OpenCodeMarkdownSection", "11", "-OpenCodeMarkdownCaptureText",
          "Uma afirmação com uma nota explicativa", "-OpenCodeMarkdownCaptureTop", "240"]
        app.launch()
        XCTAssertTrue(transcript.waitForExistence(timeout: 25))
        let reference = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value CONTAINS 'Uma afirmação com uma nota explicativa'")).firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 20))
        // The driver aligns three seconds after the transcript settles.
        Thread.sleep(forTimeInterval: 4)
        var aligned = CGRect.null
        for _ in 0..<40 where aligned != reference.frame {
          aligned = reference.frame
          Thread.sleep(forTimeInterval: 0.5)
        }
        let paragraphText = try XCTUnwrap((reference.value as? String)?.components(separatedBy: "\n\n")
          .first { $0.hasPrefix("Uma afirmação com uma nota explicativa") })
        // The note wraps on the narrower iPhone 14; a single-line prefix width
        // otherwise taps outside the text view instead of its inline reference.
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 22.5)
        let storage = NSTextStorage(string: paragraphText, attributes: [
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
        app.coordinate(withNormalizedOffset: .zero)
          .withOffset(CGVector(dx: reference.frame.minX + note.midX, dy: 240 + note.midY)).tap()
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

  func testCurrencyTableAndInlineHTMLDark() throws { try currency("openchamber-dark") }
  func testCurrencyTableAndInlineHTMLLight() throws { try currency("openchamber-light") }

  /// The synthetic `markdown-currency-fixture` reproduces a financial answer: `R$` values in a right-aligned table,
  /// bold results, an inline formula, display math and a `<sub>` sources note.
  private func currency(_ theme: String) throws {
    continueAfterFailure = false
    app.launchArguments = ["-OpenCodeServerURL", ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177", "-OpenCodeTheme", theme,
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "top", "-OpenCodeMarkdownFixture",
      "-OpenCodeMarkdownFixtureDocument", "markdown-currency-fixture", "-OpenCodeMarkdownTableWrap", "YES"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    let table = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'markdown-table-content-'")).firstMatch
    XCTAssertTrue(table.waitForExistence(timeout: 20))
    reveal(table, transcript: transcript)
    capture(app, "currency-\(theme)-table")
    func cell(_ value: String) -> XCUIElement {
      table.textViews.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }
    for value in ["Cenário", "Resultado estimado em reais", "R$ 24.310,55", "Prejuízo de R$ 19.875,42", "US$ 4.120,00"] {
      XCTAssertTrue(cell(value).waitForExistence(timeout: 5), value)
    }
    // Cells hold their text, not a formula, and the first column starts at the table's leading edge.
    XCTAssertGreaterThanOrEqual(cell("Cenário").frame.minX, table.frame.minX)
    let rows = [["Cenário", "Venda", "Valor bruto estimado", "Resultado estimado em reais"],
      ["Só ações A", "120 ACME", "R$ 24.310,55", "Prejuízo de R$ 19.875,42"]]
    for row in rows {
      let frames = row.map { cell($0).frame }
      for (left, right) in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.5, "\(row)") }
    }
    // A number is one word: at most `R$` and the number on two lines, never the number split across more.
    let number = cell("R$ 24.310,55")
    XCTAssertLessThan(number.frame.height, 2.5 * UIFontMetrics(forTextStyle: .body).scaledValue(for: 22.5))
    let note = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value CONTAINS 'Fontes: Corretora Exemplo'")).firstMatch
    reveal(note, transcript: transcript)
    let text = note.value as? String ?? ""
    for tag in ["<sub>", "</sub>", "<kbd>", "<b>", "<br>", "<small>"] { XCTAssertFalse(text.contains(tag), tag) }
    XCTAssertTrue(text.contains("x2, negrito, itálico, sublinhado, riscado, código, texto pequeno, linha\nquebrada e <span>tag desconhecida</span>."))
    let prices = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'response-' AND value CONTAINS 'Preços entre'")).firstMatch
    XCTAssertTrue((prices.value as? String ?? "").contains("Preços entre $5 e $10, R$30 ou US$12, moedas R$x e US$. e $HOME continuam texto; x^2 + y^2 = r^2 continua"))
    capture(app, "currency-\(theme)-note")
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
