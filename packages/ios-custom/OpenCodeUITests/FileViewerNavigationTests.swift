import XCTest

@MainActor final class FileViewerNavigationTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  override func record(_ issue: XCTIssue) {
    var issue = issue
    issue.add(XCTAttachment(screenshot: MainActor.assumeIsolated { XCUIScreen.main.screenshot() }))
    super.record(issue)
  }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme,
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_VIEWER_" + role])]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    return app
  }
  /// Joined response prose exposes no per-link accessibility elements, so each link has its own session whose
  /// whole message is that link (see `script/test-file-viewer.py`); opening one relaunches into it.
  private func open(_ label: String, app: XCUIApplication) {
    let key = String(label.dropFirst("Abrir ".count)).replacingOccurrences(of: "doc ", with: "DOC_").uppercased()
    guard let session = environment["OPENCODE_VIEWER_LINK_" + key] else { return XCTFail("No session for \(label)") }
    app.terminate()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenSession", session]
    app.launch()
    let text = app.descendants(matching: .any).matching(NSPredicate(format: "elementType != %d AND (value CONTAINS %@ OR label CONTAINS %@)", XCUIElement.ElementType.navigationBar.rawValue, label, label)).firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 25), label)
    text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 10)).tap()
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "viewer-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func expect(_ element: XCUIElement, value: String, timeout: TimeInterval = 5, _ message: String = "") {
    let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed, message)
  }

  private func openFeedImage(_ app: XCUIApplication) {
    let thumbnail = app.buttons["feed-image-Quadro"]
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 25))
    thumbnail.tap()
  }
  private func title(_ app: XCUIApplication, _ name: String) {
    XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 20), name)
  }
  /// A drag in the middle band, clear of the paging buttons on the edges.
  private func drag(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat = 0, velocity: XCUIGestureVelocity = .fast) {
    let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
    start.press(forDuration: 0.03, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)), withVelocity: velocity, thenHoldForDuration: 0)
  }

  func testTapsAndNudgesKeepZoomUntilAnExplicitDoubleTap() throws {
    for role in ["LINKS", "FEED"] {
      let app = try launch(role)
      if role == "LINKS" { open("Abrir PNG", app: app) } else { openFeedImage(app) }
      title(app, role == "LINKS" ? "a-imagem.png" : "Quadro")
      let image = app.images["fullscreen-image"]
      XCTAssertTrue(image.waitForExistence(timeout: 25))
      expect(image, value: "Ajustada à tela")
      image.pinch(withScale: 3, velocity: 2)
      expect(image, value: "Ampliada")
      let window = app.windows.firstMatch
      for (index, point) in [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.35, dy: 0.3), CGVector(dx: 0.65, dy: 0.7),
        CGVector(dx: 0.5, dy: 0.85)].enumerated() {
        window.coordinate(withNormalizedOffset: point).tap()
        Thread.sleep(forTimeInterval: 0.6)
        expect(image, value: "Ampliada", "\(role) single tap \(index)")
      }
      // Two quick touches that nudge the image used to be read as a double tap and reset the zoom.
      for distance in [8.0, 10.0] {
        drag(app, dx: distance)
        drag(app, dx: -distance)
        Thread.sleep(forTimeInterval: 0.8)
        expect(image, value: "Ampliada", "\(role) nudges \(distance)")
      }
      drag(app, dx: -160)
      window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      Thread.sleep(forTimeInterval: 0.6)
      expect(image, value: "Ampliada", "\(role) pan then tap")
      screenshot("zoom-kept-" + role.lowercased())
      image.doubleTap()
      expect(image, value: "Ajustada à tela")
      image.doubleTap()
      expect(image, value: "Ampliada")
      app.terminate()
    }
  }

  func testSiblingArrowsAndSwipeRespectZoom() throws {
    let app = try launch("LINKS")
    open("Abrir PNG", app: app)
    title(app, "a-imagem.png")
    let previous = app.buttons["file-previous"]
    let next = app.buttons["file-next"]
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    XCTAssertFalse(previous.exists)
    XCTAssertEqual(next.value as? String, "2 de 13")
    screenshot("first-sibling")
    next.tap()
    title(app, "b-foto.jpg")
    XCTAssertTrue(previous.waitForExistence(timeout: 10))
    let image = app.images["fullscreen-image"]
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    expect(image, value: "Ajustada à tela")
    drag(app, dx: -220)
    title(app, "c-animacao.gif")
    drag(app, dx: 220)
    title(app, "b-foto.jpg")
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    image.pinch(withScale: 3, velocity: 2)
    expect(image, value: "Ampliada")
    drag(app, dx: -220)
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(app.navigationBars["b-foto.jpg"].exists, "a zoomed image pans instead of paging")
    expect(image, value: "Ampliada")
    screenshot("zoomed-no-paging")
    image.doubleTap()
    expect(image, value: "Ajustada à tela")
    drag(app, dx: -220)
    title(app, "c-animacao.gif")
    previous.tap()
    title(app, "b-foto.jpg")
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    expect(image, value: "Ajustada à tela", timeout: 5, "a new file starts without zoom")
    app.buttons["Fechar"].tap()

    open("Abrir TXT", app: app)
    title(app, "n-texto.txt")
    XCTAssertTrue(previous.waitForExistence(timeout: 15))
    XCTAssertFalse(next.exists)
    XCTAssertEqual(previous.value as? String, "12 de 13")
    screenshot("last-sibling")
    drag(app, dx: 220)
    title(app, "l-audio.m4a")
    app.buttons["Fechar"].tap()

    open("Abrir MD", app: app)
    title(app, "f-notas.md")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Notas do visualizador'")).firstMatch.waitForExistence(timeout: 15))
    drag(app, dx: -220)
    title(app, "g-dados.json")
    drag(app, dx: -220)
    title(app, "h-codigo.ts")
    drag(app, dx: -220)
    title(app, "i-documento.pdf")
    Thread.sleep(forTimeInterval: 1)
    drag(app, dx: -220)
    title(app, "j-video.mp4")
    app.buttons["Fechar"].tap()

    open("Abrir externo", app: app)
    title(app, "fora.png")
    XCTAssertTrue(app.images["fullscreen-image"].waitForExistence(timeout: 20))
    // Files outside the Session directory page through their own folder too.
    // Server localeCompare order puts fora-2.png first.
    XCTAssertTrue(previous.waitForExistence(timeout: 15))
    XCTAssertFalse(next.exists)
    XCTAssertEqual(previous.value as? String, "1 de 2")
    drag(app, dx: 220)
    title(app, "fora-2.png")
    XCTAssertFalse(previous.exists)
    app.buttons["Fechar"].tap()
    app.terminate()

    let data = try launch("DATA")
    let embedded = data.buttons["feed-image-Embutida"]
    XCTAssertTrue(embedded.waitForExistence(timeout: 25))
    embedded.tap()
    XCTAssertTrue(data.images["fullscreen-image"].waitForExistence(timeout: 20))
    Thread.sleep(forTimeInterval: 2)
    XCTAssertFalse(data.buttons["file-next"].exists || data.buttons["file-previous"].exists)
    data.terminate()

    let feed = try launch("FEED")
    openFeedImage(feed)
    title(feed, "Quadro")
    XCTAssertTrue(feed.buttons["file-next"].waitForExistence(timeout: 15))
    feed.buttons["file-next"].tap()
    title(feed, "b-foto.jpg")
    feed.terminate()
  }

  func testExplorerFilesKeepZoomAndPageInsideAndAboveTheSession() throws {
    let app = try launch("LINKS")
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    let directory = app.buttons["session-details-directory"]
    XCTAssertTrue(directory.waitForExistence(timeout: 10))
    directory.tap()
    let file = app.buttons["file-explorer-file-a-imagem.png"]
    XCTAssertTrue(file.waitForExistence(timeout: 15))
    file.tap()
    title(app, "a-imagem.png")
    let image = app.images["fullscreen-image"]
    XCTAssertTrue(image.waitForExistence(timeout: 20))
    image.pinch(withScale: 3, velocity: 2)
    expect(image, value: "Ampliada")
    for point in [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.4, dy: 0.7)] {
      app.windows.firstMatch.coordinate(withNormalizedOffset: point).tap()
      Thread.sleep(forTimeInterval: 0.6)
      expect(image, value: "Ampliada")
    }
    drag(app, dx: -220)
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(app.navigationBars["a-imagem.png"].exists)
    let next = app.buttons["file-next"]
    XCTAssertTrue(next.waitForExistence(timeout: 10))
    next.tap()
    title(app, "b-foto.jpg")
    screenshot("explorer-sibling")
    app.navigationBars["b-foto.jpg"].buttons["Fechar"].tap()

    app.buttons["file-explorer-up"].tap()
    let above = app.buttons["file-explorer-file-acima.png"]
    XCTAssertTrue(above.waitForExistence(timeout: 15))
    above.tap()
    title(app, "acima.png")
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    XCTAssertEqual(next.value as? String, "2 de 2")
    XCTAssertFalse(app.buttons["file-previous"].exists)
    drag(app, dx: -220)
    title(app, "acima.txt")
    XCTAssertTrue(app.buttons["file-previous"].waitForExistence(timeout: 5))
    screenshot("explorer-above-root")
    app.navigationBars["acima.txt"].buttons["Fechar"].tap()
    app.terminate()
  }

  func testMarkdownDocumentsOpenRendered() throws {
    let app = try launch("DOCS")
    for (label, name, text) in [("FORMATACAO", "a-formatacao.md", "Formatação"), ("README", "b-readme.md", "OpenCode iOS (custom)"),
      ("OUTRO", "d-outro.md", "Outro documento"), ("VAZIO", "e-vazio.md", "")] {
      open("Abrir doc " + label, app: app)
      title(app, name)
      if text.isEmpty {
        XCTAssertTrue(app.staticTexts["Documento vazio"].waitForExistence(timeout: 20), name)
      } else {
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 20), name)
      }
      if label == "README" {
        // A long document scrolls to its end while only nearby slices are mounted.
        let top = app.textViews.matching(NSPredicate(format: "value CONTAINS 'Native iOS client'")).firstMatch
        for _ in 0..<40 { app.swipeUp(velocity: .fast) }
        // Far from the top, its slice is unmounted rather than kept in memory.
        XCTAssertFalse(top.exists)
        XCTAssertGreaterThan(app.textViews.count, 0)
        screenshot("markdown-readme-end")
      }
      XCTAssertEqual(app.state, .runningForeground, name)
      screenshot("markdown-" + label.lowercased())
      app.buttons["Fechar"].tap()
      XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    }
    app.terminate()
  }

  func testMarkdownTablesCodeImagesLinksAndSource() throws {
    let app = try launch("DOCS")
    open("Abrir doc RECURSOS", app: app)
    title(app, "c-recursos.md")
    // Front matter is a YAML code block, not a heading.
    XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'title: Recursos do visualizador' OR label CONTAINS 'title: Recursos do visualizador'")).firstMatch.waitForExistence(timeout: 20))
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Recursos do visualizador'")).firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Texto um pouco mais longo'")).firstMatch.waitForExistence(timeout: 10))
    screenshot("markdown-recursos-top")
    let document = app.windows.firstMatch
    let relative = app.buttons["feed-image-Imagem relativa"]
    for _ in 0..<8 where !relative.exists || !relative.isHittable {
      document.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(relative.waitForExistence(timeout: 20), "image relative to the file")
    XCTAssertTrue(app.buttons["feed-image-Imagem da pasta acima"].waitForExistence(timeout: 20))
    screenshot("markdown-recursos-images")
    let link = app.descendants(matching: .any).matching(NSPredicate(format: "(value CONTAINS %@ OR label CONTAINS %@) AND elementType IN %@",
      "Abrir o outro documento", "Abrir o outro documento",
      [XCUIElement.ElementType.textView, .link, .staticText].map(\.rawValue))).firstMatch
    for _ in 0..<6 where !link.exists || !link.isHittable { document.swipeUp(velocity: .slow) }
    XCTAssertTrue(link.waitForExistence(timeout: 10))
    link.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 10)).tap()
    title(app, "d-outro.md")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Outro documento'")).firstMatch.waitForExistence(timeout: 20))
    screenshot("markdown-linked-file")
    app.buttons["file-back"].tap()
    title(app, "c-recursos.md")
    XCTAssertFalse(app.buttons["file-back"].exists)
    let toggle = app.buttons["file-markdown-source"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    toggle.tap()
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS '## Tabela' AND value CONTAINS 'tags: [ios, markdown]'")).firstMatch.waitForExistence(timeout: 10))
    screenshot("markdown-source")
    toggle.tap()
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Recursos do visualizador'")).firstMatch.waitForExistence(timeout: 10))
    app.terminate()
  }

  func testMarkdownFromExplorerAndSiblingPaging() throws {
    let app = try launch("DOCS")
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    let directory = app.buttons["session-details-directory"]
    XCTAssertTrue(directory.waitForExistence(timeout: 10))
    directory.tap()
    let folder = app.buttons["file-explorer-folder-docs"]
    XCTAssertTrue(folder.waitForExistence(timeout: 15))
    folder.tap()
    let file = app.buttons["file-explorer-file-a-formatacao.md"]
    XCTAssertTrue(file.waitForExistence(timeout: 15))
    file.tap()
    title(app, "a-formatacao.md")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Formatação'")).firstMatch.waitForExistence(timeout: 20))
    screenshot("markdown-explorer")
    let next = app.buttons["file-next"]
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    next.tap()
    title(app, "b-readme.md")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'OpenCode iOS (custom)'")).firstMatch.waitForExistence(timeout: 20))
    drag(app, dx: -220)
    title(app, "c-recursos.md")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Recursos do visualizador'")).firstMatch.waitForExistence(timeout: 20))
    XCTAssertEqual(app.state, .runningForeground)
    screenshot("markdown-explorer-paged")
    app.navigationBars["c-recursos.md"].buttons["Fechar"].tap()
    app.terminate()
  }

  /// The reported reload: while a reply streams, the image's transcript row scrolls away and is recycled; the next
  /// scene deactivation (Notification Center, Control Center, background) used to rebuild the viewer at fit.
  func testZoomSurvivesStreamingAndSceneDeactivation() throws {
    let signals = URL(fileURLWithPath: try XCTUnwrap(environment["OPENCODE_VIEWER_SIGNALS"]))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for role in ["FEED", "LINK", "DATA"] {
      let app = try launch(role == "LINK" ? "FEED" : role)
      switch role {
      case "FEED": openFeedImage(app)
      case "LINK": open("Abrir PNG", app: app)
      default:
        let embedded = app.buttons["feed-image-Embutida"]
        XCTAssertTrue(embedded.waitForExistence(timeout: 25))
        embedded.tap()
      }
      let image = app.images["fullscreen-image"]
      XCTAssertTrue(image.waitForExistence(timeout: 25), role)
      image.pinch(withScale: 3, velocity: 2)
      expect(image, value: "Ampliada", role)
      if role == "FEED" {
        // A long Luna 6 / low reply in the same Session follows the tail past the image row.
        try "FEED".write(to: signals.appendingPathComponent("zoomed"), atomically: true, encoding: .utf8)
        let done = signals.appendingPathComponent("done")
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !FileManager.default.fileExists(atPath: done.path) { Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "background reply")
        expect(image, value: "Ampliada", "\(role) after streaming")
      }
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.001)).press(forDuration: 0.1,
        thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
      Thread.sleep(forTimeInterval: 2)
      springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).press(forDuration: 0.1,
        thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
      Thread.sleep(forTimeInterval: 2)
      expect(image, value: "Ampliada", "\(role) after Notification Center")
      XCUIDevice.shared.press(.home)
      Thread.sleep(forTimeInterval: 3)
      app.activate()
      Thread.sleep(forTimeInterval: 3)
      XCTAssertTrue(image.waitForExistence(timeout: 10), role)
      expect(image, value: "Ampliada", "\(role) after background")
      screenshot("zoom-kept-after-background-" + role.lowercased())
      app.terminate()
    }
  }

  func testFileKinds() throws {
    let app = try launch("LINKS")
    let kinds: [(String, String, String)] = [("PNG", "a-imagem.png", "image"), ("JPG", "b-foto.jpg", "image"),
      ("GIF", "c-animacao.gif", "image"), ("HEIC", "d-foto.heic", "image"), ("SVG", "e-vetor.svg", "preview"),
      ("MD", "f-notas.md", "preview"), ("JSON", "g-dados.json", "preview"), ("TS", "h-codigo.ts", "preview"),
      ("PDF", "i-documento.pdf", "preview"), ("MP4", "j-video.mp4", "player"), ("WAV", "k-audio.wav", "player"),
      ("M4A", "l-audio.m4a", "player"), ("OPAQUE", "m-binario.opaque", "unsupported"), ("TXT", "n-texto.txt", "preview")]
    for (label, name, kind) in kinds {
      open("Abrir " + label, app: app)
      title(app, name)
      switch kind {
      case "image": XCTAssertTrue(app.images["fullscreen-image"].waitForExistence(timeout: 20), name)
      case "player":
        let player = app.otherElements["file-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 20), name)
        expect(player, value: "Reproduzindo", timeout: 15, name)
      case "unsupported": XCTAssertTrue(app.staticTexts["file-unsupported"].waitForExistence(timeout: 20), name)
      default: XCTAssertTrue(app.descendants(matching: .any)["file-preview"].waitForExistence(timeout: 20), name)
      }
      if let text = ["MD": "Notas do visualizador", "JSON": "JSON preservado", "TS": "TypeScript preservado",
        "TXT": "Texto simples do visualizador"][label] {
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 10), name)
      }
      if label == "SVG" { XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), name) }
      if label == "PDF" {
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'visualizador PDF' OR value CONTAINS 'visualizador PDF'")).firstMatch.waitForExistence(timeout: 15), name)
      }
      Thread.sleep(forTimeInterval: 1.5)
      screenshot("kind-" + label.lowercased())
      app.buttons["Fechar"].tap()
      XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
    }
    app.terminate()
  }
}
