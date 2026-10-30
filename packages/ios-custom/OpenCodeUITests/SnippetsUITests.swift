import XCTest

/// Você ▸ Snippets and the conversation shortcuts against an owned sandbox prepared by `script/test-snippets.py`: an
/// empty catalog, a fake repository with its project and a conversation there with one user message. Every snippet
/// these tests create is removed by the script.
@MainActor final class SnippetsUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private var project: String { environment["OPENCODE_SNIPPETS_PROJECT"] ?? "" }
  override func setUp() { continueAfterFailure = false }

  private func launch(session: String? = nil) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
      + (session.map { ["-OpenCodeOpenSession", $0] } ?? [])
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    try app.requireSandbox()
    return app
  }

  private func shot(_ name: String) {
    // A fresh simulator covers its first keyboard with Apple's QuickPath introduction.
    let introduction = XCUIApplication().buttons.matching(
      NSPredicate(format: "label == 'Continue' OR label == 'Continuar'")).firstMatch
    if introduction.exists {
      introduction.tap()
      XCTAssertTrue(introduction.waitForNonExistence(timeout: 5))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "snippets-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  /// Scrolls the topmost list until `target` is fully on screen above the keyboard.
  private func reveal(_ target: XCUIElement, _ app: XCUIApplication) {
    // The editor's form: the last list on screen (a sheet's comes after the transcript).
    let list = app.collectionViews.element(boundBy: max(0, app.collectionViews.count - 1))
    // Drag in the form's left margin, outside its rows, above the keyboard and its suggestion bar: a slow swipe that
    // starts on Conteúdo moves its cursor instead of scrolling.
    func drag(_ distance: CGFloat) {
      let keyboard = app.keyboards.firstMatch
      let bottom = min(list.frame.maxY, keyboard.exists ? keyboard.frame.minY - 50 : app.frame.maxY - 40)
      let start = app.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: 7, dy: distance < 0 ? bottom - 10 : list.frame.minY + 90))
      start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: .slow,
        thenHoldForDuration: 0.3)
    }
    // Rows below the fold are not built until scrolled to.
    for _ in 0..<6 where !target.waitForExistence(timeout: 1) { drag(-260) }
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    for _ in 0..<8 {
      let keyboard = app.keyboards.firstMatch
      let bottom = keyboard.exists ? keyboard.frame.minY : app.frame.maxY - 40
      if target.isHittable && target.frame.maxY < bottom && target.frame.minY > 130 { return }
      drag(target.frame.minY <= 130 ? 200 : -200)
    }
  }

  private func type(_ text: String, into id: String, _ app: XCUIApplication, atEnd: Bool = false) {
    let field = element(id, app)
    reveal(field, app)
    if atEnd { field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() } else { field.tap() }
    field.typeText(text)
  }

  private func save(_ app: XCUIApplication, title: String) {
    let save = app.buttons["snippet-save"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
      object: save)], timeout: 10), .completed, "Salvar should enable")
    save.tap()
    XCTAssertTrue(app.navigationBars[title].waitForNonExistence(timeout: 15), "the editor should close after saving")
  }

  private func row(_ name: String, _ app: XCUIApplication) -> XCUIElement { app.buttons["snippet-row-" + name].firstMatch }

  /// Empty state, a name error, create, edit, duplicate, a scope conflict, a project snippet that replaces a global
  /// one, its chip, and deleting with confirmation; the Você row counts what is left.
  func testLibraryCreateEditDuplicateDelete() throws {
    let app = try launch()
    defer { app.terminate() }
    app.openYou()
    let entry = app.buttons["settings-snippets"]
    XCTAssertTrue(entry.waitForExistence(timeout: 15))
    entry.tap()
    XCTAssertTrue(element("snippets-empty", app).waitForExistence(timeout: 15), "the sandbox catalog must start empty")
    shot("empty")

    // A name with a space is refused while typing.
    app.buttons["snippets-empty-new"].tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    let name = app.textFields["snippet-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    if !(name.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { name.tap() }
    name.typeText("revisar código")
    let problem = element("snippet-name-problem", app)
    XCTAssertTrue(problem.waitForExistence(timeout: 5))
    XCTAssertTrue(problem.label.contains("Sem espaços nem #, @, $"))
    XCTAssertFalse(app.buttons["snippet-save"].isEnabled)
    shot("error-keyboard")

    // Create.
    name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
    XCTAssertTrue(element("snippet-name-available", app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("snippet-name-available", app).label.contains("Disponível nos globais"))
    type("Revisa o diff", into: "snippet-description", app)
    type("Revise o diff atual e aponte riscos de regressão.", into: "snippet-content", app)
    let add = app.buttons["snippet-alias-add"]
    reveal(add, app)
    add.tap()
    type("review", into: "snippet-alias-input", app)
    app.buttons["snippet-alias-confirm"].tap()
    XCTAssertTrue(app.buttons["snippet-alias-remove-review"].waitForExistence(timeout: 5))
    shot("editor-new")
    save(app, title: "Novo snippet")
    XCTAssertTrue(row("revisar", app).waitForExistence(timeout: 10))
    XCTAssertTrue(row("revisar", app).label.contains("review"))

    // Edit.
    row("revisar", app).tap()
    XCTAssertTrue(app.navigationBars["Editar snippet"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["snippet-save"].isEnabled, "nothing changed yet")
    type(" e aponta riscos", into: "snippet-description", app, atEnd: true)
    save(app, title: "Editar snippet")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS 'Revisa o diff e aponta riscos'"), object: row("revisar", app))],
      timeout: 10), .completed)

    // Duplicate: the copy opens in the editor with a free name; saving confirms it.
    row("revisar", app).swipeLeft()
    XCTAssertTrue(app.buttons["Duplicar"].waitForExistence(timeout: 5))
    app.buttons["Duplicar"].tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["snippet-name"].value as? String, "revisar-copia")
    save(app, title: "Novo snippet")
    XCTAssertTrue(row("revisar-copia", app).waitForExistence(timeout: 10))

    // The same name in the same scope is refused; another scope takes it and replaces the global one there.
    app.buttons["snippets-new"].tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    if !(app.textFields["snippet-name"].value(forKey: "hasKeyboardFocus") as? Bool ?? false) {
      app.textFields["snippet-name"].tap()
    }
    app.textFields["snippet-name"].typeText("review")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS 'já é atalho de #revisar nos globais'"),
      object: element("snippet-name-problem", app))], timeout: 5), .completed)
    app.textFields["snippet-name"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "revisar")
    XCTAssertTrue(element("snippet-name-problem", app).label.contains("Já existe #revisar nos globais"))
    shot("error-conflict")
    let scope = element("snippet-scope", app)
    reveal(scope, app)
    scope.tap()
    let choice = app.buttons["snippet-scope-" + project]
    XCTAssertTrue(choice.waitForExistence(timeout: 10), "the conversation's project is listed")
    choice.tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    XCTAssertTrue(element("snippet-name-available", app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("snippet-name-available", app).label.contains("substitui o global"))
    type("Revise seguindo o guia deste projeto.", into: "snippet-content", app)
    save(app, title: "Novo snippet")
    let replacing = app.buttons.matching(NSPredicate(format: "identifier == 'snippet-row-revisar' AND label CONTAINS 'substitui o global'")).firstMatch
    XCTAssertTrue(replacing.waitForExistence(timeout: 10))
    XCTAssertTrue(element("snippets-section-" + project, app).exists)
    shot("list")

    // A project's chip shows only its snippets.
    let chip = app.buttons["snippets-filter-" + project]
    XCTAssertTrue(chip.waitForExistence(timeout: 5))
    chip.tap()
    XCTAssertTrue(element("snippets-section-Globais", app).waitForNonExistence(timeout: 5))
    XCTAssertTrue(element("snippets-count", app).label.contains("1 de 3"))
    app.buttons["snippets-filter-all"].tap()
    XCTAssertTrue(element("snippets-section-Globais", app).waitForExistence(timeout: 5))

    // Delete asks first.
    row("revisar-copia", app).swipeLeft()
    XCTAssertTrue(app.buttons["Apagar"].waitForExistence(timeout: 5))
    app.buttons["Apagar"].tap()
    let confirm = app.buttons["Apagar snippet"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    shot("delete-confirmation")
    confirm.tap()
    XCTAssertTrue(row("revisar-copia", app).waitForNonExistence(timeout: 10))

    // Back in Você, the row counts the two left.
    app.navigationBars.buttons["Você"].tap()
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '2' OR label CONTAINS '2'"), object: entry)], timeout: 10), .completed)
    shot("you-row")
  }

  /// Salvar como snippet from a sent message and from the composer's selection, Novo snippet from the `#` panel, and
  /// the panel listing snippets saved meanwhile (here and by another client) without reopening the conversation.
  func testConversationShortcutsAndLiveHash() throws {
    let session = try XCTUnwrap(environment["OPENCODE_SNIPPETS_SESSION"])
    let message = try XCTUnwrap(environment["OPENCODE_SNIPPETS_MESSAGE"])
    let app = try launch(session: session)
    defer { app.terminate() }
    let editor = app.textViews["conversation-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 30))

    // From the message: content, a name from its first words and the conversation's project.
    let prompt = element("user-prompt-" + message, app)
    XCTAssertTrue(prompt.waitForExistence(timeout: 15))
    prompt.press(forDuration: 1)
    let menu = app.buttons["Salvar como snippet"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    shot("message-menu")
    menu.tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["snippet-name"].value as? String, "revise-o-diff")
    XCTAssertEqual(app.textViews["snippet-content"].value as? String, "Revise o diff atual e aponte riscos de regressão.")
    XCTAssertTrue(element("snippet-name-available", app).label.contains("Disponível em " + project))
    shot("save-from-message")
    let messageScope = element("snippet-scope", app)
    reveal(messageScope, app)
    XCTAssertEqual(messageScope.value as? String, project)
    save(app, title: "Novo snippet")

    // `#` lists it at once.
    editor.tap()
    editor.typeText("#revise")
    let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '#revise-o-diff'")).firstMatch
    XCTAssertTrue(saved.waitForExistence(timeout: 10), "# should list the snippet saved from the message")
    shot("hash-after-message")

    // Novo snippet at the end of the panel takes the query as its name; back in the composer `#` lists it.
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "deploy-ios")
    XCTAssertTrue(app.staticTexts["Nenhum item correspondente"].waitForExistence(timeout: 10))
    let create = app.buttons["snippet-panel-new"]
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    shot("hash-new")
    create.tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["snippet-name"].value as? String, "deploy-ios")
    let panelScope = element("snippet-scope", app)
    reveal(panelScope, app)
    XCTAssertEqual(panelScope.value as? String, project)
    type("Publique a versão no TestFlight interno.", into: "snippet-content", app)
    save(app, title: "Novo snippet")
    let deploy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '#deploy-ios'")).firstMatch
    XCTAssertTrue(deploy.waitForExistence(timeout: 10), "the composer returns with # listing the new snippet")
    XCTAssertTrue((editor.value as? String)?.contains("#deploy-ios") == true, "the draft keeps its text")

    // Another client saves one while the panel is open: it shows without reopening anything.
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "externo")
    XCTAssertTrue(app.staticTexts["Nenhum item correspondente"].waitForExistence(timeout: 10))
    try saveFromAnotherClient(name: "externo-api")
    let external = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '#externo-api'")).firstMatch
    XCTAssertTrue(external.waitForExistence(timeout: 15), "# should follow rpc.custom.snippets.updated")
    shot("hash-live")

    // Gerenciar snippets opens Você ▸ Snippets over the conversation; closing it returns to the composer.
    // It opens on the conversation's project, like the Mac's.
    app.buttons["snippet-panel-manage"].tap()
    XCTAssertTrue(row("deploy-ios", app).waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["snippets-filter-" + project].isSelected)
    XCTAssertFalse(row("externo-api", app).exists)
    shot("manage")
    app.buttons["snippets-filter-all"].tap()
    XCTAssertTrue(row("externo-api", app).waitForExistence(timeout: 10))
    app.buttons["snippets-close"].tap()
    XCTAssertTrue(row("deploy-ios", app).waitForNonExistence(timeout: 10))
    XCTAssertTrue(external.waitForExistence(timeout: 10), "the composer returns with the panel open")
    editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))

    // From the composer's selection: the editor gets a copy and the draft stays as it is.
    let text = "Rode os testes no tema claro e no escuro."
    editor.typeText(text)
    // Three taps select the paragraph, here the whole draft, and show the edit menu.
    editor.tap(withNumberOfTaps: 3, numberOfTouches: 1)
    // The edit menu's items: right after Cortar and Copiar, on its first page.
    let fromSelection = app.menuItems["Salvar como snippet"]
    XCTAssertTrue(fromSelection.waitForExistence(timeout: 5))
    shot("selection-menu")
    fromSelection.tap()
    XCTAssertTrue(app.navigationBars["Novo snippet"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.textViews["snippet-content"].value as? String, text)
    XCTAssertEqual(app.textFields["snippet-name"].value as? String, "rode-os-testes")
    save(app, title: "Novo snippet")
    XCTAssertEqual(editor.value as? String, text, "Salvar como snippet keeps the composer's text")
  }

  /// `custom.snippets/save` straight to the sandbox, as another app would.
  private func saveFromAnotherClient(name: String) throws {
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + "/api/rpc/custom.snippets/save")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["input": [
      "id": "ios-ui-" + UUID().uuidString.lowercased(), "name": name, "description": "Salvo por outro cliente",
      "aliases": [String](), "content": "Texto salvo fora do app.",
    ]])
    let done = expectation(description: "save")
    let status = Status()
    URLSession.shared.dataTask(with: request) { _, response, _ in
      status.code = (response as? HTTPURLResponse)?.statusCode ?? 0
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 15)
    XCTAssertEqual(status.code, 200)
  }
}

/// The answer's status, written once by URLSession's callback before the expectation is fulfilled.
private final class Status: @unchecked Sendable {
  var code = 0
}
