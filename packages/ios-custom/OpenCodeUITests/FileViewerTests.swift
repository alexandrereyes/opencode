import XCTest

@MainActor final class FileViewerTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeMarkdownTableWrap", "YES",
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_FILE_" + role])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    return app
  }
  private func tap(_ label: String, app: XCUIApplication) {
    let link = app.links[label].firstMatch
    if link.waitForExistence(timeout: 5) {
      let target = app.links.matching(identifier: label).allElementsBoundByIndex.min { $0.frame.width < $1.frame.width } ?? link
      // TextKit exposes a full-width parent as a Link as well as its inline range.
      target.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: min(40, target.frame.width / 2), dy: 12)).tap()
      return
    }
    let text = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", label)).firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 5))
    text.tap()
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "files-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testTextPDFAndShare() throws {
    for (role, label, filename) in [("INLINE", "notes.txt", "notes.txt"), ("CODE", "Abrir código", "source.ts"), ("PDF", "Abrir PDF", "example.pdf"),
      ("ABSOLUTE", "Abrir externo", "outside.txt"), ("TILDE", "Abrir pasta pessoal", "notes.txt")] {
      let app = try launch(role)
      tap(label, app: app)
      XCTAssertTrue(app.navigationBars[filename].waitForExistence(timeout: 20))
      XCTAssertTrue(app.otherElements["file-preview"].waitForExistence(timeout: 20))
      if role == "INLINE" || role == "TILDE" {
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Arquivo de verificação'")).firstMatch.waitForExistence(timeout: 15))
      }
      if role == "PDF" {
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'OpenCode - PDF fixture'")).firstMatch.waitForExistence(timeout: 20))
      }
      if role == "CODE" {
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'TypeScript preservado'")).firstMatch.waitForExistence(timeout: 15))
      }
      screenshot(role.lowercased())
      app.buttons["Copiar caminho"].tap()
      XCTAssertTrue(app.buttons["Caminho copiado"].waitForExistence(timeout: 5))
      app.buttons["Compartilhar"].tap()
      XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
      screenshot("share-" + role.lowercased())
      app.terminate()
    }
  }
  func testVideoAndAudioPlayFromDownloadedFiles() throws {
    for (role, label, filename) in [("VIDEO", "Abrir vídeo", "video.mp4"), ("AUDIO", "Abrir áudio", "audio.wav"),
      ("IMAGEVIDEO", "Vídeo incorporado", "video.mp4")] {
      let app = try launch(role)
      if role == "IMAGEVIDEO" {
        XCTAssertTrue(app.buttons["file-media-" + label].waitForExistence(timeout: 15))
        app.buttons["file-media-" + label].tap()
      } else { tap(label, app: app) }
      XCTAssertTrue(app.navigationBars[filename].waitForExistence(timeout: 20))
      XCTAssertTrue(app.otherElements["file-player"].waitForExistence(timeout: 20))
      let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Reproduzindo'"), object: app.otherElements["file-player"])
      XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed)
      screenshot(role.lowercased())
      app.buttons["Compartilhar"].tap()
      screenshot("share-" + role.lowercased())
      app.terminate()
    }
  }
  func testImagesTablesAndExistingZoomViewer() throws {
    let app = try launch("IMAGE")
    tap("Abrir imagem", app: app)
    XCTAssertTrue(app.navigationBars["image.png"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.images["fullscreen-image"].waitForExistence(timeout: 20))
    screenshot("image")
    app.buttons["Compartilhar"].tap()
    XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
    screenshot("share-image")
    app.terminate()
    let table = try launch("TABLE")
    let image = table.buttons["feed-image-Quadro"]
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    screenshot("table")
    image.tap()
    XCTAssertTrue(table.buttons["Fechar"].waitForExistence(timeout: 10))
    XCTAssertTrue(table.images["fullscreen-image"].waitForExistence(timeout: 10))
    screenshot("table-zoom")
    table.buttons["Compartilhar"].tap()
    XCTAssertTrue(table.otherElements["ActivityListView"].waitForExistence(timeout: 15))
    screenshot("table-share")
    table.terminate()
  }
  func testMissingUnknownAndLargeFileConsent() throws {
    let missing = try launch("MISSING")
    tap("Abrir ausente", app: missing)
    XCTAssertTrue(missing.staticTexts["Arquivo não encontrado no Mac"].waitForExistence(timeout: 15))
    XCTAssertTrue(missing.buttons["Tentar novamente"].exists)
    screenshot("missing")
    missing.terminate()
    let unknown = try launch("UNKNOWN")
    tap("Abrir binário", app: unknown)
    XCTAssertTrue(unknown.buttons["Compartilhar arquivo"].waitForExistence(timeout: 15))
    screenshot("unknown")
    unknown.terminate()
    let big = try launch("BIG")
    tap("Abrir grande", app: big)
    XCTAssertTrue(big.buttons["Baixar arquivo"].waitForExistence(timeout: 15))
    screenshot("large-consent")
    big.buttons["Cancelar"].tap()
    XCTAssertTrue(big.collectionViews["conversation-transcript"].waitForExistence(timeout: 5))
    big.terminate()
  }

  func testTableRowsMeasureIndependentlyAndStayTopAligned() throws {
    let media = try launch("TABLE")
    let image = media.buttons["feed-image-Quadro"]
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    let heading = media.textViews.matching(NSPredicate(format: "value == 'Imagem'")).firstMatch
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    XCTAssertLessThan(image.frame.minY - heading.frame.maxY, 32)
    XCTAssertGreaterThan(image.frame.minY - heading.frame.maxY, 16)
    print("TABLE_GEOMETRY \(theme): media header=\(image.frame.minY - heading.frame.minY), text=\(heading.frame.height)")
    let file = media.links.matching(identifier: "Abrir texto").allElementsBoundByIndex.min { $0.frame.width < $1.frame.width }
    XCTAssertEqual(try XCTUnwrap(file).frame.minY, image.frame.minY, accuracy: 3)
    screenshot("table-compact-header")
    media.terminate()

    let plain = try launch("PLAIN_TABLE")
    let short = plain.textViews.matching(NSPredicate(format: "value == 'Curto'")).firstMatch
    let long = plain.textViews.matching(NSPredicate(format: "value BEGINSWITH 'Um texto que ocupa'")).firstMatch
    XCTAssertTrue(long.waitForExistence(timeout: 10))
    XCTAssertEqual(short.frame.minY, long.frame.minY, accuracy: 1)
    XCTAssertGreaterThan(long.frame.height, short.frame.height + 20)
    screenshot("table-plain-top-aligned")
    plain.terminate()

    let wide = try launch("WIDE_TABLE")
    let scroll = wide.scrollViews["markdown-table-content-0"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 10))
    let end = wide.textViews.matching(NSPredicate(format: "value == 'Coluna final visível'")).firstMatch
    let before = end.frame.minX
    scroll.swipeLeft(velocity: .slow)
    XCTAssertLessThan(end.frame.minX, before - 80)
    screenshot("table-wide-scrolled")
    wide.terminate()
  }

  func testFormattingFixtureTablesHaveCompactIndependentRows() throws {
    let cases = [
      (["Recurso", "Exemplo", "Para que serve"], "Negrito"),
      (["Produto", "Quantidade", "Valor"], "Café ☕"),
      (["Identificador", "Descrição", "Responsável", "Estado", "Observação"], "ios-render-001"),
      (["Etapa", "Situação"], "Planejamento"),
    ]
    for (index, item) in cases.enumerated() {
      let app = try launch("FORMAT_\(index + 1)")
      let scroll = app.scrollViews["markdown-table-content-1"]
      XCTAssertTrue(scroll.waitForExistence(timeout: 15))
      let cells = item.0.map { title in
        app.textViews.matching(NSPredicate(format: "value == %@", title)).firstMatch
      }
      let transcript = app.collectionViews["conversation-transcript"]
      for _ in 0..<8 {
        if cells[0].frame.minY >= transcript.frame.minY + 80 { break }
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.4))
          .press(forDuration: 0.01, thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
      }
      XCTAssertGreaterThanOrEqual(cells[0].frame.minY, transcript.frame.minY + 80)
      let first = app.textViews.matching(NSPredicate(format: "value == %@", item.1)).firstMatch
      XCTAssertTrue(first.waitForExistence(timeout: 5))
      let bottom = cells.map(\.frame.maxY).max() ?? 0
      XCTAssertEqual(first.frame.minY - bottom, 20, accuracy: 2)
      screenshot("format-table-\(index + 1)")
      if index == 2 {
        scroll.swipeLeft(velocity: .slow)
        screenshot("format-table-wide-scrolled")
      }
      app.terminate()
    }
  }
}
