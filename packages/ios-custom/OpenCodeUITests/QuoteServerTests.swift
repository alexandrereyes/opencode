import XCTest

/// Pending quotes stored by `custom.quotes` (the web shares them). Fixtures come from `script/test-quotes.py`.
@MainActor final class QuoteServerTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }
  private func value(_ key: String) throws -> String { try XCTUnwrap(environment["OPENCODE_QUOTE_" + key]) }
  private func launch(_ kind: String, extra: [String: String] = [:]) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark", "-OpenCodeOpenSession", try value(kind)]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    for (key, value) in extra { app.launchEnvironment[key] = value }
    app.launch()
    open(app)
    return app
  }
  private func open(_ app: XCUIApplication) {
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"),
      evaluatedWith: transcript)], timeout: 30), .completed)
  }
  private func shoot(_ name: String) {
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "server-" + name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "dark")
    shot.lifetime = .keepAlways
    add(shot)
  }
  private func card(_ app: XCUIApplication, count: Int) -> Bool {
    let label = app.buttons["draft-quotes"]
    let predicate = NSPredicate(format: "label CONTAINS %@", "Citações · \(count)")
    return XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: label)], timeout: 20) == .completed
  }
  private func markers(_ app: XCUIApplication) -> XCUIElementQuery {
    app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quote-marker-'"))
  }
  /// The sandbox RPC, as the web calls it.
  private func rpc(_ method: String, _ input: [String: Any]) throws -> [String: Any] {
    let session = try value(environment["OPENCODE_QUOTE_RPC_KIND"] ?? "LIVE")
    var request = URLRequest(url: URL(string: TestSandbox.url + "/api/rpc/custom.quotes/" + method + "?location%5Bdirectory%5D="
      + (try value("DIRECTORY").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let credential = Data(("opencode:" + (try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"]))).utf8).base64EncodedString()
    request.setValue("Basic " + credential, forHTTPHeaderField: "Authorization")
    var body = input
    if body["sessionID"] == nil { body["sessionID"] = session }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["input": body])
    let done = expectation(description: method)
    nonisolated(unsafe) var output: [String: Any] = [:]
    URLSession.shared.dataTask(with: request) { data, _, _ in
      output = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 30)
    return output["output"] as? [String: Any] ?? output
  }
  private func list(_ session: String) throws -> [[String: Any]] {
    try rpc("list", ["sessionID": session])["quotes"] as? [[String: Any]] ?? []
  }
  private func waitServer(_ session: String, _ check: @escaping ([[String: Any]]) -> Bool) throws {
    for _ in 0..<40 {
      if check(try list(session)) { return }
      Thread.sleep(forTimeInterval: 0.5)
    }
    XCTFail("The server never reached the expected quotes: \(try list(session))")
  }
  private func comment(_ app: XCUIApplication, kind: String, text: String) throws {
    let source = try value(kind + "_SOURCE")
    let response = app.textViews["response-\(source)-\(source):text:0"]
    XCTAssertTrue(response.waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 10))
    response.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).press(forDuration: 1)
    let comment = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comentar'")).firstMatch
    XCTAssertTrue(comment.waitForExistence(timeout: 5))
    comment.tap()
    let editor = app.textViews["comment-composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.typeText(text)
  }

  /// Created on the iPhone with a photo: stored on the server, still there after leaving and relaunching.
  func testCommentWithPhotoIsStoredOnTheServerAndSurvivesRelaunch() throws {
    let session = try value("CREATE")
    let app = try launch("CREATE")
    defer { app.terminate() }
    try comment(app, kind: "CREATE", text: "Comentário no servidor.")
    app.buttons.matching(identifier: "Adicionar").allElementsBoundByIndex.last(where: \.isHittable)?.tap()
    XCTAssertTrue(app.buttons["Fotos"].waitForExistence(timeout: 5))
    app.buttons["Fotos"].tap()
    let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
    photo.tap()
    let confirm = app.buttons["Add"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remover Foto-'")).firstMatch.waitForExistence(timeout: 20))
    app.buttons["Concluir"].tap()
    XCTAssertTrue(card(app, count: 1))
    try waitServer(session) { quotes in
      quotes.count == 1 && quotes[0]["comment"] as? String == "Comentário no servidor."
        && (quotes[0]["attachments"] as? [[String: Any]])?.count == 1
        && (quotes[0]["anchor"] as? [String: Any])?["coordinate"] as? String == "source"
        && (quotes[0]["anchor"] as? [String: Any])?["prefix"] != nil
    }
    XCTAssertTrue(markers(app).firstMatch.waitForExistence(timeout: 10))
    shoot("created")
    app.terminate()
    app.launch()
    open(app)
    XCTAssertTrue(card(app, count: 1))
    app.buttons["draft-quotes"].tap()
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Foto-'")).firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Comentário no servidor."].exists)
    shoot("reopened")
    // The comment editor reads the photo back from the server.
    app.buttons["Editar citação"].firstMatch.tap()
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remover Foto-'")).firstMatch.waitForExistence(timeout: 20))
    shoot("editor-photo")
    app.buttons["Cancelar"].tap()
  }

  /// A change made through the RPC (as the web does, with its rendered-text anchor) shows up live.
  func testServerChangesAppearLiveWithWebAnchors() throws {
    let app = try launch("LIVE")
    defer { app.terminate() }
    XCTAssertTrue(card(app, count: 1))
    XCTAssertTrue(markers(app).firstMatch.waitForExistence(timeout: 15))
    let source = try value("LIVE_SOURCE")
    let text = try value("LIVE_TEXT")
    _ = try rpc("save", ["quote": [
      "id": "web-live-" + UUID().uuidString, "messageID": source, "partID": source + ":text:0",
      "text": "o botão Meu negócio", "comment": "Comentário vindo do web.",
      "commentPrompt": [["type": "text", "start": 0, "end": 24, "content": "Comentário vindo do web."]],
      // The web counts textContent offsets; they never match the iPhone's flattening.
      "anchor": ["start": text.utf16.count + 40, "end": text.utf16.count + 59, "exact": "o botão Meu negócio",
        "coordinate": "rendered", "prefix": "Depois, ", "suffix": " some."],
      "attachments": [],
    ]])
    XCTAssertTrue(card(app, count: 2))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: markers(app))], timeout: 15), .completed)
    app.buttons["draft-quotes"].tap()
    XCTAssertTrue(app.staticTexts["Comentário vindo do web."].waitForExistence(timeout: 10))
    shoot("live-added")
    let first = try XCTUnwrap(try list(try value("LIVE")).first?["id"] as? String)
    _ = try rpc("remove", ["id": first])
    XCTAssertTrue(card(app, count: 1))
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: markers(app))], timeout: 15), .completed)
    shoot("live-removed")
  }

  /// Trash removes on the server; sending clears only the sent quotes, after admission, and the message keeps them.
  func testRemoveAndSendClearTheServer() throws {
    let session = try value("SEND")
    let app = try launch("SEND", extra: ["OPENCODE_TEST_PROMPT_FIXTURE": session + ":0:admit"])
    defer { app.terminate() }
    XCTAssertTrue(card(app, count: 2))
    app.buttons["draft-quotes"].tap()
    let remove = app.buttons.matching(NSPredicate(format: "label == 'Remover citação'")).firstMatch
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    remove.tap()
    XCTAssertTrue(card(app, count: 1))
    try waitServer(session) { $0.count == 1 }
    let kept = try XCTUnwrap(try list(session).first?["id"] as? String)
    let composer = app.textViews["conversation-composer"]
    composer.tap()
    composer.typeText("Envio com citação do servidor.")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.buttons["draft-quotes"].waitForNonExistence(timeout: 20))
    try waitServer(session) { $0.isEmpty }
    // Admission-only fixture: the prompt waits in the inbox with the same quote metadata as before.
    let inbox = try XCTUnwrap(try inboxQuotes(session))
    XCTAssertEqual(inbox.first?["id"] as? String, kept)
    XCTAssertEqual(inbox.first?["comment"] as? String, "Comentário semeado 2.")
    shoot("sent")
    app.terminate()
    app.launch()
    open(app)
    XCTAssertFalse(app.buttons["draft-quotes"].waitForExistence(timeout: 5))
  }
  private func inboxQuotes(_ session: String) throws -> [[String: Any]]? {
    var request = URLRequest(url: URL(string: TestSandbox.url + "/api/session/" + session + "/inbox")!)
    let credential = Data(("opencode:" + (try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"]))).utf8).base64EncodedString()
    request.setValue("Basic " + credential, forHTTPHeaderField: "Authorization")
    let done = expectation(description: "inbox")
    nonisolated(unsafe) var output: Any?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      output = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 30)
    let items = (output as? [String: Any])?["data"] as? [[String: Any]] ?? output as? [[String: Any]] ?? []
    let payload = items.last { ($0["payload"] as? [String: Any])?["metadata"] != nil }?["payload"] as? [String: Any]
    return (payload?["metadata"] as? [String: Any])?["quotes"] as? [[String: Any]]
  }

  /// An old `draft.json` (quote with a photo) and its hidden marks move to the server once.
  func testLegacyDraftMigratesToTheServer() throws {
    let session = try value("MIGRATE")
    let app = try launch("MIGRATE")
    defer { app.terminate() }
    XCTAssertTrue(card(app, count: 1))
    try waitServer(session) { quotes in
      quotes.first?["id"] as? String == "legacy-quote" && (quotes.first?["attachments"] as? [[String: Any]])?.count == 1
    }
    XCTAssertEqual(try rpc("list", ["sessionID": session])["dismissed"] as? [String], ["legacy-sent"])
    app.buttons["draft-quotes"].tap()
    XCTAssertTrue(app.staticTexts["Comentário legado."].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["legado.png"].exists)
    shoot("migrated")
    app.terminate()
    app.launch()
    open(app)
    XCTAssertTrue(card(app, count: 1))
    XCTAssertEqual(try list(session).count, 1)
  }

  /// A server without `custom.quotes` (before `custom:update`) keeps today's local quotes.
  func testServerWithoutQuotesRPCKeepsLocalQuotes() throws {
    let session = try value("LOCAL")
    let unavailable = ["OPENCODE_TEST_QUOTES_UNAVAILABLE": "1"]
    let app = try launch("LOCAL", extra: unavailable)
    defer { app.terminate() }
    try comment(app, kind: "LOCAL", text: "Comentário local.")
    app.buttons["Concluir"].tap()
    XCTAssertTrue(card(app, count: 1))
    XCTAssertTrue(markers(app).firstMatch.waitForExistence(timeout: 10))
    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(try list(session).isEmpty)
    shoot("local")
    app.terminate()
    app.launchEnvironment = app.launchEnvironment.merging(unavailable) { $1 }
    app.launch()
    open(app)
    XCTAssertTrue(card(app, count: 1))
    XCTAssertTrue(try list(session).isEmpty)
  }
}
