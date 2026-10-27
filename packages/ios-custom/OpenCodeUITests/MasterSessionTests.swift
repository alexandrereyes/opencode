import XCTest

@MainActor final class MasterSessionTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var serverURL: String { environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4179" }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch(old: Bool = false, session: String? = nil) throws -> XCUIApplication {
    continueAfterFailure = false
    XCTAssertEqual(try XCTUnwrap(URL(string: serverURL)).host, "127.0.0.1")
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", serverURL, "-OpenCodeTheme", theme]
    if let session { app.launchArguments += ["-OpenCodeOpenSession", session] }
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    if old { app.launchEnvironment["OPENCODE_MASTER_OLD_SERVER"] = "1" }
    app.launch()
    if session == nil {
      XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
      app.tabBars.buttons["Sessões"].tap()
    }
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = (name == "ordinary-chat-header" ? "" : "master-") + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func request(_ path: String, body: Data? = nil, method: String? = nil) async throws -> Data {
    var request = URLRequest(url: URL(string: serverURL + path)!)
    request.httpMethod = method ?? (body == nil ? "GET" : "POST")
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
    return data
  }
  func testEmptyFirstSendHiddenAndTrashStartsFresh() async throws {
    let app = try launch()
    defer { app.terminate() }
    let accessory = app.buttons["master-accessory"]
    XCTAssertTrue(accessory.waitForExistence(timeout: 30))
    accessory.tap()
    XCTAssertTrue(app.staticTexts["master-empty"].waitForExistence(timeout: 30))
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["agent-picker"].exists)
    XCTAssertEqual(app.staticTexts["child-agent"].label, "Agente: Mestra")
    XCTAssertTrue(app.buttons["model-picker"].exists)
    shot("empty")
    if environment["OPENCODE_TEST_CHEAP_INFERENCE"] == "1" {
      app.buttons["model-picker"].tap()
      let search = app.searchFields.firstMatch
      XCTAssertTrue(search.waitForExistence(timeout: 5))
      search.tap()
      search.typeText("gpt-6-luna")
      let luna = app.buttons["choose-llm-proxy/gpt-6-luna"]
      for _ in 0..<5 {
        if luna.exists && luna.isHittable { break }
        app.swipeUp(velocity: .slow)
      }
      shot("cheap-model-search")
      XCTAssertTrue(luna.waitForExistence(timeout: 10))
      luna.tap()
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Esforço' AND label CONTAINS 'Luna'")).firstMatch.tap()
      app.buttons["low"].tap()
      app.buttons["fechar"].tap()
      app.buttons["Concluir"].tap()
    }
    input.typeText("Responda somente MESTRA OK, sem usar ferramentas.")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.buttons["master-trash"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    struct Profile: Decodable {
      let output: Output
      struct Output: Decodable { let data: Data }
      struct Data: Decodable { let masterSessions: [String: String] }
    }
    let profile = try JSONDecoder().decode(Profile.self, from: await request("/api/rpc/custom.preferences/get", body: Data(#"{"input":{}}"#.utf8)))
    let id = try XCTUnwrap(profile.output.data.masterSessions["local"])
    struct Created: Decodable {
      let data: Info
      struct Info: Decodable { let agent: String; let model: Model }
      struct Model: Decodable { let id: String; let variant: String? }
    }
    let created = try JSONDecoder().decode(Created.self, from: await request("/api/session/" + id))
    XCTAssertEqual(created.data.agent, "mestra")
    XCTAssertEqual(app.buttons["conversation-header-avatar"].value as? String, "Sessão mestra")
    XCTAssertTrue(app.staticTexts["conversation-header-subtitle"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["conversation-header-subtitle"].label.contains("session-"))
    struct Capability: Decodable {
      let output: Info
      struct Info: Decodable { let model: Created.Model? }
    }
    let capability = try JSONDecoder().decode(Capability.self, from: await request("/api/rpc/custom.master/info", body: Data(#"{"input":{}}"#.utf8)))
    if environment["OPENCODE_TEST_CHEAP_INFERENCE"] == "1" {
      XCTAssertEqual(created.data.model.id, "gpt-6-luna")
      XCTAssertEqual(created.data.model.variant, "low")
    } else if let preferred = capability.output.model {
      XCTAssertEqual(created.data.model.id, preferred.id)
      XCTAssertEqual(created.data.model.variant, preferred.variant)
    } else {
      struct Default: Decodable { let data: Created.Model? }
      let fallback = try JSONDecoder().decode(Default.self, from: await request("/api/model/default"))
      XCTAssertEqual(created.data.model.id, fallback.data?.id)
      XCTAssertTrue(created.data.model.variant == nil || created.data.model.variant == "default")
    }
    _ = try await request("/api/session/" + id + "/form", body: Data(#"{"title":"Pedido da própria mestra","metadata":{"kind":"question"},"fields":[{"key":"answer","type":"string"}]}"#.utf8))
    shot("created")
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 10))
    // The fixed master title exists only inside the accessory, never as a session row.
    XCTAssertEqual(app.buttons.matching(identifier: "master-accessory").count, 1)
    XCTAssertFalse(app.buttons["session-row-" + id].exists)
    XCTAssertTrue(accessory.label.contains("Tudo em dia"))
    shot("hidden")
    accessory.tap()
    XCTAssertTrue(app.buttons["master-trash"].waitForExistence(timeout: 20))
    app.buttons["master-trash"].tap()
    XCTAssertTrue(app.staticTexts["master-empty"].waitForExistence(timeout: 30))
    XCTAssertFalse(app.alerts.firstMatch.exists)
    shot("trash-empty")
    app.buttons["Voltar"].tap()
    let archived = app.buttons["sessions-archived"]
    app.revealSessionRow(archived)
    archived.tap()
    XCTAssertTrue(app.navigationBars["Arquivadas"].waitForExistence(timeout: 15))
    shot("archived")
  }
  func testDeletedMasterIsRecreatedWhenOpened() async throws {
    struct Ensured: Decodable {
      let output: Output
      struct Output: Decodable { let sessionID: String; let created: Bool }
    }
    let ensure = Data(#"{"input":{}}"#.utf8)
    let old = try JSONDecoder().decode(Ensured.self, from: await request("/api/rpc/custom.master/ensure", body: ensure))
    // Deleting it elsewhere (as the web does) used to leave the app opening a 404.
    _ = try await request("/api/session/" + old.output.sessionID, method: "DELETE")
    let app = try launch()
    defer { app.terminate() }
    let accessory = app.buttons["master-accessory"]
    XCTAssertTrue(accessory.waitForExistence(timeout: 30))
    accessory.tap()
    struct Profile: Decodable {
      let output: Output
      struct Output: Decodable { let data: Data }
      struct Data: Decodable { let masterSessions: [String: String]? }
    }
    var pointer = old.output.sessionID
    for _ in 0..<60 where pointer == old.output.sessionID {
      try await Task.sleep(for: .milliseconds(500))
      let profile = try JSONDecoder().decode(Profile.self, from: await request("/api/rpc/custom.preferences/get", body: ensure))
      pointer = profile.output.data.masterSessions?["local"] ?? pointer
    }
    XCTAssertNotEqual(pointer, old.output.sessionID)
    XCTAssertTrue(app.buttons["master-trash"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    try await Task.sleep(for: .seconds(2))
    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '404'")).firstMatch.exists)
    let current = try JSONDecoder().decode(Ensured.self, from: await request("/api/rpc/custom.master/ensure", body: ensure))
    XCTAssertEqual(current.output.sessionID, pointer)
    XCTAssertFalse(current.output.created)
    struct Info: Decodable { let data: Session; struct Session: Decodable { let agent: String } }
    let info = try JSONDecoder().decode(Info.self, from: await request("/api/session/" + current.output.sessionID))
    XCTAssertEqual(info.data.agent, "mestra")
    shot("recreated")
  }
  func testOrdinaryChatHeaderUsesTitleAndHidesManagedDirectory() throws {
    let app = try launch(session: XCTUnwrap(environment["OPENCODE_TEST_CHAT"]))
    defer { app.terminate() }
    let folder = URL(fileURLWithPath: try XCTUnwrap(environment["OPENCODE_TEST_CHAT_DIRECTORY"])).lastPathComponent
    let avatar = app.buttons["conversation-header-avatar"]
    XCTAssertTrue(avatar.waitForExistence(timeout: 30))
    XCTAssertEqual(avatar.value as? String, "CT")
    let subtitle = app.staticTexts["conversation-header-subtitle"]
    XCTAssertTrue(subtitle.waitForExistence(timeout: 20))
    XCTAssertTrue(subtitle.label.contains("Luna"))
    XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch.exists)
    shot("ordinary-chat-header")
    // A root chat's avatar and title switch sessions; Detalhes da sessão stays in the … menu.
    XCTAssertTrue(app.buttons["conversation-switcher"].exists)
    app.openConversationOptions(expect: "Detalhes da sessão").tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Diretório"].exists)
    XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch.exists)
    app.buttons["Fechar"].tap()
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sem repositório'")).firstMatch.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Diretório de trabalho"].exists)
    XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch.exists)
  }
  func testTargetUserMessageShowsMasterOrigin() throws {
    let app = try launch(session: XCTUnwrap(environment["OPENCODE_TEST_MASTER_TARGET"]))
    defer { app.terminate() }
    let marker = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'master-origin-'")).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 30))
    XCTAssertEqual(marker.label, "Sessão mestra")
    shot("origin")
  }
  func testOldServerKeepsSessionsAndExplainsUpgrade() throws {
    let app = try launch(old: true)
    defer { app.terminate() }
    let accessory = app.buttons["master-accessory"]
    XCTAssertTrue(accessory.waitForExistence(timeout: 20))
    accessory.tap()
    XCTAssertTrue(app.staticTexts["Atualize o servidor para usar a Sessão mestra"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.textViews["conversation-composer"].exists)
    shot("old-server")
    app.buttons["Voltar"].tap()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 10))
  }
}
