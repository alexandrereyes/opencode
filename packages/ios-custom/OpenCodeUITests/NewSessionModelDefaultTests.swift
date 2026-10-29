import XCTest

/// Needs an isolated sandbox with Chats (`custom.chats`), Luna 6 and Astra 6 (`llm-proxy`). The first case
/// sends two tiny Luna 6/low prompts to new managed chats; the second sends nothing. Both restore the
/// sandbox's saved default model for new sessions.
@MainActor final class NewSessionModelDefaultTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private let luna = #"{"providerID":"llm-proxy","modelID":"gpt-6-luna","variant":"low"}"#
  private let astra = #"{"providerID":"llm-proxy","modelID":"gpt-6-astra","variant":"medium"}"#

  /// Chooses Luna 6 · low on Nova sessão, creates the chat, and finds the choice again on the next
  /// Nova sessão. Nova sessão from that chat's menu inherits it without replacing the saved default.
  func test01ChosenModelAndEffortBecomeTheNextDefault() async throws {
    try await keepDefault()
    try await mutate(#"{"type":"model.default","model":null}"#)
    // The picker only lists visible models.
    try await mutate(#"{"type":"model.visibility","providerID":"llm-proxy","modelID":"gpt-6-luna","visibility":"show"}"#)
    let app = try launch()
    defer { app.terminate() }
    openNewSession(app)
    let picker = app.buttons["model-picker"]
    XCTAssertTrue(enabled(picker))
    XCTAssertNotEqual(picker.value as? String, "Luna 6 · low")
    shot("before-choice")
    picker.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("gpt-6-luna")
    let choice = app.buttons["choose-llm-proxy/gpt-6-luna"]
    for _ in 0..<5 {
      if choice.exists && choice.isHittable { break }
      app.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(choice.waitForExistence(timeout: 10))
    choice.tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Esforço' AND label CONTAINS 'Luna'")).firstMatch.tap()
    app.buttons["low"].tap()
    app.buttons["fechar"].tap()
    app.buttons["Concluir"].tap()
    XCTAssertTrue(value(picker, "Luna 6 · low"))
    send(app, "Responda apenas: OK padrão")
    try await expectDefault("gpt-6-luna", "low")

    app.buttons["Voltar"].tap()
    openNewSession(app)
    XCTAssertTrue(value(app.buttons["model-picker"], "Luna 6 · low"))
    shot("next-new-session")
    app.buttons["Voltar"].tap()

    // Inheriting from a conversation is not a choice made on this screen.
    try await mutate(#"{"type":"model.default","model":\#(astra)}"#)
    let filter = app.buttons["filter-chats"]
    XCTAssertTrue(filter.waitForExistence(timeout: 10))
    filter.tap()
    let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-row-'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    app.openConversationOptions(expect: "Nova sessão").tap()
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 20))
    XCTAssertTrue(value(app.buttons["model-picker"], "Luna 6 · low"))
    shot("inherited")
    send(app, "Responda apenas: OK herdado")
    try await Task.sleep(for: .seconds(3))
    try await expectDefault("gpt-6-astra", "medium")
    app.buttons["Voltar"].tap()
    if filter.waitForExistence(timeout: 10) { filter.tap() }
  }

  /// A saved default that is unavailable, or lost its effort, falls back to the previous choice.
  func test02UnavailableDefaultFallsBack() async throws {
    try await keepDefault()
    try await mutate(#"{"type":"model.default","model":null}"#)
    try await mutate(#"{"type":"model.variant","providerID":"llm-proxy","modelID":"gpt-6-luna","variant":"medium"}"#)
    let app = try launch()
    defer { app.terminate() }
    openNewSession(app)
    let picker = app.buttons["model-picker"]
    XCTAssertTrue(enabled(picker))
    let fallback = try XCTUnwrap(picker.value as? String)
    app.buttons["Voltar"].tap()

    try await mutate(#"{"type":"model.default","model":{"providerID":"llm-proxy","modelID":"removed-model","variant":"low"}}"#)
    openNewSession(app)
    XCTAssertTrue(value(app.buttons["model-picker"], fallback))
    shot("missing-model")
    app.buttons["Voltar"].tap()

    try await mutate(#"{"type":"model.default","model":{"providerID":"llm-proxy","modelID":"gpt-6-luna","variant":"gone"}}"#)
    openNewSession(app)
    XCTAssertTrue(value(app.buttons["model-picker"], "Luna 6 · medium"))
    shot("missing-effort")
    app.buttons["Voltar"].tap()
  }

  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    app.showSessions()
    return app
  }
  private func openNewSession(_ app: XCUIApplication) {
    if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
    XCTAssertTrue(app.buttons["Nova sessão"].waitForExistence(timeout: 20))
    app.buttons["Nova sessão"].tap()
    XCTAssertTrue(app.buttons["Projeto: Chats"].waitForExistence(timeout: 20))
    XCTAssertTrue(enabled(app.buttons["model-picker"]))
  }
  private func send(_ app: XCUIApplication, _ text: String) {
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText(text)
    XCTAssertTrue(enabled(app.buttons["Enviar mensagem"]))
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
  }
  private func enabled(_ element: XCUIElement) -> Bool {
    XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: element)], timeout: 30) == .completed
  }
  private func value(_ element: XCUIElement, _ expected: String) -> Bool {
    XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", expected), object: element)], timeout: 20) == .completed
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "model-default-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private struct Saved: Codable, Equatable {
    let providerID: String
    let modelID: String
    let variant: String?
  }
  private func saved() async throws -> Saved? {
    struct Profile: Decodable {
      let output: Output
      struct Output: Decodable { let data: Data }
      struct Data: Decodable { let models: Models? }
      struct Models: Decodable { let `default`: Saved? }
    }
    return try JSONDecoder().decode(Profile.self, from: await rpc("get", "{}")).output.data.models?.default
  }
  private var original: String?
  private func keepDefault() async throws {
    original = try await saved().map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
  }
  override func tearDown() async throws {
    if let original { try await mutate(#"{"type":"model.default","model":\#(original)}"#) }
    try await super.tearDown()
  }
  private func expectDefault(_ modelID: String, _ variant: String) async throws {
    let expected = Saved(providerID: "llm-proxy", modelID: modelID, variant: variant)
    for _ in 0..<40 {
      if try await saved() == expected { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    let current = try await saved()
    XCTAssertEqual(current, expected)
  }
  private func mutate(_ intent: String) async throws { _ = try await rpc("mutate", intent) }
  private func rpc(_ method: String, _ input: String) async throws -> Data {
    var request = URLRequest(url: URL(string: TestSandbox.url + "/api/rpc/custom.preferences/" + method)!)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"input":\#(input)}"#.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue(
      "Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return data
  }
}
