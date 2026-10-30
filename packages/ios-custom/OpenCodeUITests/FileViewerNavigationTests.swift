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
    try app.requireSandbox()
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
    let previous = app.descendants(matching: .any).matching(identifier: "file-previous").firstMatch
    let next = app.descendants(matching: .any).matching(identifier: "file-next").firstMatch
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    XCTAssertFalse(previous.exists)
    XCTAssertEqual(next.value as? String, "2 de 13")
    screenshot("first-sibling")
    drag(app, dx: -220)
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
    drag(app, dx: 220)
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
    XCTAssertFalse(data.descendants(matching: .any).matching(identifier: "file-next").firstMatch.exists || data.descendants(matching: .any).matching(identifier: "file-previous").firstMatch.exists)
    data.terminate()

    let feed = try launch("FEED")
    openFeedImage(feed)
    title(feed, "Quadro")
    XCTAssertTrue(feed.descendants(matching: .any).matching(identifier: "file-next").firstMatch.waitForExistence(timeout: 15))
    drag(feed, dx: -220)
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
    let next = app.descendants(matching: .any).matching(identifier: "file-next").firstMatch
    XCTAssertTrue(next.waitForExistence(timeout: 10))
    image.doubleTap()
    expect(image, value: "Ajustada à tela")
    drag(app, dx: -220)
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
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "file-previous").firstMatch.exists)
    drag(app, dx: -220)
    title(app, "acima.txt")
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "file-previous").firstMatch.waitForExistence(timeout: 5))
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
        // The 480 KB README highlights dozens of code blocks; parsing it alone took 100–190 s in a Debug build on a
        // Mac busy with other simulators (30/10).
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.waitForExistence(timeout: name == "b-readme.md" ? 240 : 60), name)
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
    let next = app.descendants(matching: .any).matching(identifier: "file-next").firstMatch
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    drag(app, dx: -220)
    title(app, "b-readme.md")
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'OpenCode iOS (custom)'")).firstMatch.waitForExistence(timeout: 240))
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

  /// Taps the only text of a Session whose message is a single folder reference, retrying while the server
  /// confirms it and the link appears.
  private func tapFolder(_ role: String, text: String, app: XCUIApplication) -> Bool {
    let element = app.collectionViews["conversation-transcript"].descendants(matching: .any).matching(NSPredicate(
      format: "identifier BEGINSWITH 'response-' AND (value CONTAINS %@ OR label CONTAINS %@)", text, text)).firstMatch
    XCTAssertTrue(element.waitForExistence(timeout: 25), role)
    let header = app.staticTexts["file-explorer-path"]
    for _ in 0..<6 {
      element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 20, dy: 0)).tap()
      if header.waitForExistence(timeout: 3) { return true }
    }
    return false
  }

  func testFolderLinksOpenTheExplorerAndFilesTheViewer() throws {
    let folder = try XCTUnwrap(environment["OPENCODE_VIEWER_DOCS_FOLDER"])
    let outside = try XCTUnwrap(environment["OPENCODE_VIEWER_OUTSIDE_FOLDER"])
    for (role, text, path) in [("FOLDER_CODE", "docs/", folder), ("FOLDER_CODE_BARE", "./docs", folder),
      ("LINK_PASTA", "Abrir pasta", folder), ("FOLDER_ABSOLUTE", outside, outside)] {
      let app = try launch(role)
      XCTAssertTrue(tapFolder(role, text: text, app: app), role)
      let header = app.staticTexts["file-explorer-path"]
      XCTAssertEqual(header.label, path, role)
      if role == "FOLDER_CODE" {
        // The explorer lists the folder, opens its files in the viewer and climbs with ../.
        let file = app.buttons["file-explorer-file-d-outro.md"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        screenshot("folder-explorer")
        file.tap()
        title(app, "d-outro.md")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS 'Outro documento'")).firstMatch.waitForExistence(timeout: 20))
        screenshot("folder-explorer-file")
        app.navigationBars["d-outro.md"].buttons["Fechar"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        app.buttons["file-explorer-up"].tap()
        let parent = NSPredicate(format: "label == %@", URL(fileURLWithPath: folder).deletingLastPathComponent().path)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: parent, object: header)], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["file-explorer-folder-docs"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
      }
      if role == "FOLDER_ABSOLUTE" {
        XCTAssertTrue(app.buttons["file-explorer-file-fora.png"].waitForExistence(timeout: 15))
        screenshot("folder-explorer-outside")
      }
      app.buttons["Fechar"].firstMatch.tap()
      XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10), role)
      app.terminate()
    }
    // A missing folder stays plain text: tapping it opens nothing.
    let missing = try launch("FOLDER_MISSING")
    XCTAssertFalse(tapFolder("FOLDER_MISSING", text: "docs/inexistente/", app: missing))
    XCTAssertFalse(missing.navigationBars.matching(NSPredicate(format: "identifier CONTAINS 'inexistente'")).firstMatch.exists)
    screenshot("folder-missing")
    missing.terminate()
    // A file link still opens the viewer.
    let file = try launch("LINKS")
    open("Abrir MD", app: file)
    title(file, "f-notas.md")
    file.terminate()
  }

  private func webText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) -> Bool {
    app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
      .firstMatch.waitForExistence(timeout: timeout)
  }

  func testHTMLPreviewSourcePagingAndLargeFiles() throws {
    let app = try launch("LINKS")
    open("Abrir HTML_A", app: app)
    title(app, "a-estatico.html")
    XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
    XCTAssertTrue(webText(app, "Página estática do visualizador"))
    screenshot("html-static")
    let toggle = app.buttons["file-markdown-source"]
    XCTAssertEqual(toggle.label, "Ver código")
    toggle.tap()
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS '<h1>Página estática do visualizador</h1>'")).firstMatch.waitForExistence(timeout: 10))
    screenshot("html-source")
    toggle.tap()
    XCTAssertTrue(webText(app, "Página estática do visualizador"))
    // A single-file report built by its own script, reached with the paging swipe.
    let next = app.descendants(matching: .any).matching(identifier: "file-next").firstMatch
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    drag(app, dx: -220)
    title(app, "b-relatorio.html")
    XCTAssertTrue(webText(app, "3 testes, 2 passaram"), "script-built report")
    screenshot("html-report")
    drag(app, dx: 220)
    title(app, "a-estatico.html")
    XCTAssertTrue(webText(app, "Página estática do visualizador"))
    app.buttons["Fechar"].firstMatch.tap()

    open("Abrir HTML_E", app: app)
    title(app, "e-pagina.htm")
    XCTAssertTrue(webText(app, "Página HTM unificada"), ".htm renders in the same web view")
    app.buttons["Fechar"].firstMatch.tap()

    open("Abrir HTML_D", app: app)
    title(app, "d-grande.htm")
    XCTAssertTrue(app.staticTexts["Este arquivo tem mais de 25 MB. Deseja baixá-lo?"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["Baixar arquivo"].exists)
    screenshot("html-large")
    app.buttons["Cancelar"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))

    // From the explorer of Detalhes da sessão.
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    let directory = app.buttons["session-details-directory"]
    XCTAssertTrue(directory.waitForExistence(timeout: 10))
    directory.tap()
    let folder = app.buttons["file-explorer-folder-html"]
    XCTAssertTrue(folder.waitForExistence(timeout: 15))
    folder.tap()
    let file = app.buttons["file-explorer-file-b-relatorio.html"]
    XCTAssertTrue(file.waitForExistence(timeout: 15))
    file.tap()
    title(app, "b-relatorio.html")
    XCTAssertTrue(webText(app, "3 testes, 2 passaram"))
    screenshot("html-explorer")
    app.terminate()
  }

  func testHTMLPreviewIsIsolatedAndOnlyTappedLinksLeave() throws {
    let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    safari.terminate()
    let app = try launch("LINKS")
    open("Abrir HTML_C", app: app)
    title(app, "c-seguranca.html")
    XCTAssertTrue(webText(app, "Página de segurança"))
    XCTAssertTrue(webText(app, "arquivo: bloqueado"), "file: URL from the page")
    // Local files by default: no network.
    XCTAssertTrue(webText(app, "rede: falhou"))
    XCTAssertTrue(webText(app, "local: carregou"))
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "file-html-mode").firstMatch.label, "Arquivos locais, sem internet")
    // Permitir internet reloads the page alone with the network: the file next to it no longer loads.
    app.buttons["file-html-internet"].tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "file-html-mode").firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "file-html-mode").firstMatch.label, "Internet, sem arquivos locais")
    XCTAssertTrue(webText(app, "local: falhou"), "no local files with the internet allowed")
    XCTAssertTrue(webText(app, "arquivo: bloqueado"))
    // window.open, location = … and a script click on a link all ran by now; nothing left the viewer.
    Thread.sleep(forTimeInterval: 4)
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertNotEqual(safari.state, .runningForeground)
    XCTAssertTrue(app.navigationBars["c-seguranca.html"].exists)
    XCTAssertTrue(webText(app, "Página de segurança", timeout: 2), "the page was not replaced")
    screenshot("html-isolated")
    // The page reached the network, never with a credential, even when challenged.
    let log = URL(fileURLWithPath: try XCTUnwrap(environment["OPENCODE_VIEWER_PROBE_LOG"]))
    let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [[String: Any]])
    XCTAssertTrue(requests.contains { ($0["path"] as? String)?.hasPrefix("/fetch") == true || ($0["path"] as? String)?.hasPrefix("/imagem") == true })
    XCTAssertFalse(requests.contains { $0["authorization"] as? Bool == true || $0["cookie"] as? Bool == true }, "\(requests)")
    // A link the person taps opens in Safari, also with target="_blank".
    for name in ["Abrir site externo", "Abrir em nova janela"] {
      let link = app.webViews.links[name]
      XCTAssertTrue(link.waitForExistence(timeout: 10), name)
      link.tap()
      XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), name)
      app.activate()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
      XCTAssertTrue(app.navigationBars["c-seguranca.html"].waitForExistence(timeout: 10), name)
    }
    safari.terminate()
    app.terminate()
  }

  func testHTMLLocalFilesLoadInScopeAndNothingLeaks() throws {
    let app = try launch("LINKS")
    let mode = app.descendants(matching: .any).matching(identifier: "file-html-mode").firstMatch
    // Images in subfolders, a stylesheet with url() and a font, a classic script and an ES module.
    open("Abrir LOCAL_INDEX", app: app)
    title(app, "index.html")
    XCTAssertTrue(webText(app, "estado: imagens 2/2 · css ok · fonte ok · js ok · modulo ok"), "local resources")
    XCTAssertEqual(mode.label, "Arquivos locais, sem internet")
    screenshot("html-local-resources")
    app.buttons["file-html-internet"].tap()
    XCTAssertTrue(webText(app, "estado: imagens 0/2"), "the internet mode has no local files")
    screenshot("html-internet-mode")
    app.buttons["file-html-internet"].tap()
    XCTAssertTrue(webText(app, "estado: imagens 2/2 · css ok · fonte ok · js ok · modulo ok"))
    // Relative links between pages of the same scope navigate inside the preview, with a back step.
    let report = app.webViews.links["Abrir relatório de várias páginas"]
    XCTAssertTrue(report.waitForExistence(timeout: 10))
    report.tap()
    XCTAssertTrue(webText(app, "Relatório · página 1"))
    app.webViews.links["Ir para a página 2"].tap()
    XCTAssertTrue(webText(app, "Relatório · página 2"))
    XCTAssertTrue(webText(app, "fora: negado"), "../ above the Session directory")
    screenshot("html-local-report-page")
    let back = app.buttons["file-html-back"]
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(webText(app, "Relatório · página 1"))
    app.buttons["Fechar"].firstMatch.tap()

    // A page that reads a local file finds no way out.
    open("Abrir LOCAL_VAZAMENTO", app: app)
    title(app, "vazamento.html")
    XCTAssertTrue(webText(app, "segredo: lido"))
    XCTAssertTrue(webText(app, "fora: negado"))
    XCTAssertTrue(webText(app, "saída: bloqueada"))
    Thread.sleep(forTimeInterval: 3)
    XCTAssertTrue(app.navigationBars["vazamento.html"].exists)
    XCTAssertTrue(webText(app, "Tentativas de vazamento", timeout: 2), "the form post did not navigate")
    screenshot("html-local-leak-blocked")
    let log = URL(fileURLWithPath: try XCTUnwrap(environment["OPENCODE_VIEWER_PROBE_LOG"]))
    let requests = (try? JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [[String: Any]]) ?? []
    XCTAssertFalse(requests.contains { ($0["path"] as? String)?.hasPrefix("/vazamento") == true }, "\(requests)")
    app.buttons["Fechar"].firstMatch.tap()

    // The reported case: a page outside the Session with images in a subfolder; always opens on local files.
    open("Abrir LIVE", app: app)
    title(app, "index.html")
    XCTAssertTrue(webText(app, "estado: 2 de 2 imagens"))
    XCTAssertTrue(webText(app, "fora: negado"), "the page folder is the scope outside the Session")
    XCTAssertEqual(mode.label, "Arquivos locais, sem internet")
    screenshot("html-live-activities")
    app.terminate()
  }

  /// Taps the first link of an already open conversation whose whole message is that link.
  private func tapLink(_ label: String, app: XCUIApplication) {
    let text = app.collectionViews["conversation-transcript"].descendants(matching: .any).matching(NSPredicate(
      format: "value CONTAINS %@ OR label CONTAINS %@", label, label)).firstMatch
    XCTAssertTrue(text.waitForExistence(timeout: 25), label)
    text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 10)).tap()
  }

  private func openRow(_ session: String, app: XCUIApplication) {
    let row = app.buttons.matching(identifier: "session-row-" + session).firstMatch
    // Opening a conversation moves it in the list, often above the rows left on screen.
    for _ in 0..<4 where !row.isHittable { app.collectionViews.firstMatch.swipeDown(velocity: .fast) }
    app.revealSessionRow(row)
    row.tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25), session)
  }

  /// The reported bug: after closing a viewer and moving through the app, the same link stopped opening until
  /// a relaunch. The retained transcript kept actions of a conversation screen that no longer existed.
  func testLinksKeepOpeningAfterLeavingAndReturning() throws {
    let other = try XCTUnwrap(environment["OPENCODE_VIEWER_LINK_MD"])
    for (role, label, opened) in [("LINK_PNG", "Abrir PNG", "a-imagem.png"), ("LINK_PASTA", "Abrir pasta", ""),
      ("FEED", "", "Quadro")] {
      let session = try XCTUnwrap(environment["OPENCODE_VIEWER_" + role])
      let app = try launch(role)
      func openAndClose(_ round: Int) {
        if role == "FEED" {
          let thumbnail = app.buttons["feed-image-Quadro"]
          XCTAssertTrue(thumbnail.waitForExistence(timeout: 25))
          thumbnail.tap()
        } else { tapLink(label, app: app) }
        if role == "LINK_PASTA" {
          XCTAssertTrue(app.staticTexts["file-explorer-path"].waitForExistence(timeout: 20), "\(role) round \(round)")
        } else {
          XCTAssertTrue(app.navigationBars[opened].waitForExistence(timeout: 20), "\(role) round \(round)")
        }
        app.buttons["Fechar"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 10))
      }
      openAndClose(0)
      // One round trip per link kind: the reported failure happened on the first return.
      for round in 1...1 {
        // Sessões, another conversation, Você, and back to this conversation.
        app.showSessions()
        openRow(other, app: app)
        app.openYou()
        app.showSessions()
        openRow(session, app: app)
        openAndClose(round)
      }
      screenshot("links-after-navigation-" + role.lowercased())
      app.terminate()
    }
  }

  func testSiblingHintsAreSmallCornerChevronsOnlyTowardASibling() throws {
    let app = try launch("LINKS")
    open("Abrir MP4", app: app)
    title(app, "j-video.mp4")
    let player = app.otherElements["file-player"]
    XCTAssertTrue(player.waitForExistence(timeout: 20))
    expect(player, value: "Reproduzindo", timeout: 15)
    let previous = app.descendants(matching: .any).matching(identifier: "file-previous").firstMatch
    let next = app.descendants(matching: .any).matching(identifier: "file-next").firstMatch
    XCTAssertTrue(previous.waitForExistence(timeout: 15))
    XCTAssertTrue(next.exists)
    XCTAssertEqual(next.label, "Há próximo arquivo")
    XCTAssertEqual(next.value as? String, "11 de 13")
    let window = app.windows.firstMatch.frame
    // Small chevrons in the lower corners, not buttons over the middle of the picture. (VoiceOver can activate
    // them, so AX reports them as buttons; touches pass through, checked below.)
    for hint in [previous, next] {
      XCTAssertLessThanOrEqual(hint.frame.width, 22)
      XCTAssertLessThanOrEqual(hint.frame.height, 22)
      XCTAssertGreaterThan(hint.frame.minY, window.height * 0.75)
    }
    XCTAssertLessThanOrEqual(previous.frame.minX - window.minX, 14)
    XCTAssertLessThanOrEqual(window.maxX - next.frame.maxX, 14)
    // With the player's controls shown, the hints stay above its timeline.
    player.tap()
    let timeline = app.sliders.firstMatch
    if timeline.waitForExistence(timeout: 5) {
      XCTAssertLessThan(next.frame.maxY, timeline.frame.minY, "\(next.frame) over \(timeline.frame)")
    }
    screenshot("hints-video-controls")
    // A touch on a hint reaches the content: no paging.
    next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(app.navigationBars["j-video.mp4"].exists)
    // Paging is the swipe, over the video too.
    drag(app, dx: -220)
    title(app, "k-audio.wav")
    drag(app, dx: 220)
    title(app, "j-video.mp4")
    app.buttons["Fechar"].firstMatch.tap()
    // First and last files show one hint; a file alone in its folder shows none.
    open("Abrir PNG", app: app)
    title(app, "a-imagem.png")
    XCTAssertTrue(next.waitForExistence(timeout: 15))
    XCTAssertFalse(previous.exists)
    screenshot("hints-image")
    app.buttons["Fechar"].firstMatch.tap()
    open("Abrir LIVE", app: app)
    title(app, "index.html")
    XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
    Thread.sleep(forTimeInterval: 3)
    XCTAssertFalse(next.exists || previous.exists, "a single file")
    screenshot("hints-single-file")
    app.terminate()
  }

  /// Arquivos beside Fechar (approved mock "opção A"): the place above the file, the drawer with the linked file
  /// marked in its folder, opening another file, Recentes, the filter, Alterados and the session-wide search.
  func testFilesDrawer() throws {
    let app = try launch("LINKS")
    open("Abrir doc FORMATACAO", app: app)
    title(app, "a-formatacao.md")
    let position = app.staticTexts["file-position"]
    XCTAssertTrue(position.waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["file-path-line"].label.contains("fixtures, docs"), app.staticTexts["file-path-line"].label)
    // A link lands with its folder open and the file marked.
    app.buttons["file-drawer"].tap()
    // The drawer is open while its own close button is on screen.
    let panel = app.buttons["file-drawer-close"]
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    let marked = app.buttons["file-drawer-row-a-formatacao.md"]
    XCTAssertTrue(marked.waitForExistence(timeout: 20))
    XCTAssertTrue(marked.isSelected)
    XCTAssertTrue(app.buttons["file-drawer-row-docs"].label.hasSuffix("aberta"))
    screenshot("drawer-link")
    // Another file opens in the viewer, closes the drawer and counts in its folder.
    app.buttons["file-drawer-row-j-video.mp4"].tap()
    title(app, "j-video.mp4")
    XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    XCTAssertTrue(position.waitForExistence(timeout: 20))
    expectLabel(position, "10 de 13")
    drag(app, dx: -220)
    title(app, "k-audio.wav")
    expectLabel(position, "11 de 13")
    // Recentes, newest first.
    app.buttons["file-drawer"].tap()
    let latest = app.buttons["file-drawer-recent-k-audio.wav"]
    XCTAssertTrue(latest.waitForExistence(timeout: 10))
    XCTAssertTrue(latest.isSelected)
    let earlier = app.buttons["file-drawer-recent-a-formatacao.md"]
    XCTAssertTrue(earlier.exists)
    XCTAssertLessThan(latest.frame.minY, app.buttons["file-drawer-recent-j-video.mp4"].frame.minY)
    XCTAssertLessThan(app.buttons["file-drawer-recent-j-video.mp4"].frame.minY, earlier.frame.minY)
    screenshot("drawer-open")
    // The filter keeps matching names and the folders leading to them.
    let field = app.textFields["file-drawer-filter"]
    field.tap()
    field.typeText("formata")
    XCTAssertTrue(app.buttons["file-drawer-row-a-formatacao.md"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["file-drawer-row-a-imagem.png"].exists)
    app.buttons["Limpar"].firstMatch.tap()
    // Alterados: the fixture's checkout changed f-notas.md only.
    app.segmentedControls["file-drawer-changed"].buttons["Alterados"].tap()
    let changed = app.buttons["file-drawer-row-f-notas.md"]
    XCTAssertTrue(changed.waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["file-drawer-row-a-imagem.png"].exists)
    screenshot("drawer-changed")
    app.segmentedControls["file-drawer-changed"].buttons["Todos"].tap()
    XCTAssertTrue(app.buttons["file-drawer-row-k-audio.wav"].waitForExistence(timeout: 10))
    // The whole session, through the server's search.
    app.buttons["file-drawer-search"].tap()
    field.typeText("interna")
    let result = app.buttons["file-drawer-result-interna.txt"]
    XCTAssertTrue(result.waitForExistence(timeout: 20))
    result.tap()
    title(app, "interna.txt")
    XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    // Fechar Arquivos and a tap outside close it without changing the file.
    app.buttons["file-drawer"].tap()
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    app.buttons["file-drawer-close"].tap()
    XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    app.buttons["file-drawer"].tap()
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars["interna.txt"].exists)
    screenshot("drawer-file")
    app.terminate()
  }

  private func expectLabel(_ element: XCUIElement, _ label: String) {
    let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 15), .completed, "\(element.label) ≠ \(label)")
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
