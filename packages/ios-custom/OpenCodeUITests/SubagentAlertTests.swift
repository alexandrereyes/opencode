import XCTest

@MainActor final class SubagentAlertTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func id(_ role: String) throws -> String { try XCTUnwrap(environment["OPENCODE_TEST_" + role]) }
  private func api(_ path: String, body: [String: Any]? = nil, method: String = "POST") async throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:4177" + path)))
    request.httpMethod = method
    request.setValue("Basic " + Data(("opencode:" + (try id("PASSWORD"))).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
    return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
  }
  private func prompt(_ role: String, _ text: String) async throws {
    _ = try await api("/api/session/" + id(role) + "/prompt", body: ["id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), "text": text, "delivery": "steer"])
  }
  private func idle(_ role: String) async throws -> Double {
    let session = try await api("/api/session/" + id(role), method: "GET")["data"] as? [String: Any]
    return (session?["time"] as? [String: Any])?["idle"] as? Double ?? 0
  }
  private func waitForSuccess(_ role: String, after watermark: Double = 0) async throws {
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
      let session = try await api("/api/session/" + id(role), method: "GET")["data"] as? [String: Any]
      let idle = (session?["time"] as? [String: Any])?["idle"] as? Double ?? 0
      if session?["outcome"] as? String == "succeeded", idle > watermark { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTFail("A sessão não concluiu: " + role)
  }
  private func launch(_ role: String) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeTheme", theme, "-OpenCodeOpenSession", try id(role)]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try id("PASSWORD")
    app.launch()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 25))
    if role != "MISSING" {
      XCTAssertTrue(app.textViews["conversation-composer"].waitForExistence(timeout: 20))
    }
    return app
  }
  private func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testChildSendPreservesAgentAndParentResult() async throws {
    let app = try launch("CHILD")
    XCTAssertTrue(app.staticTexts["child-agent"].exists)
    XCTAssertFalse(app.buttons["agent-picker"].exists)
    XCTAssertTrue(app.buttons["Voltar à sessão principal"].exists)
    let editor = app.textViews["conversation-composer"]
    editor.tap()
    editor.typeText("Responda apenas: Filho respondeu.")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == 'Filho respondeu.'")).firstMatch.waitForExistence(timeout: 90))
    XCTAssertFalse(app.buttons["Background"].exists)
    XCTAssertFalse(app.buttons["session-alert-open"].exists)
    _ = app.descendants(matching: .any)["action-toast"].waitForNonExistence(timeout: 6)
    screenshot("child-sent")
    app.buttons["Voltar à sessão principal"].tap()
    XCTAssertTrue(app.staticTexts["Onda 7 — sessão principal"].waitForExistence(timeout: 15))
  }
  func testLiveBannersAcrossScreensAndTapNavigation() async throws {
    let app = try launch("PARENT")
    for screen in ["conversation", "sessions"] {
      if screen == "sessions" { app.buttons["Voltar"].tap() }
      for (role, text, state) in [
        ("SUCCESS", "Responda apenas: Concluido.", "Concluída"),
        ("FAILURE", "Responda oi.", "Falhou"),
        (screen == "sessions" ? "PERMISSION2" : "PERMISSION", "Use somente shell para executar exatamente git push origin neon-mountain. Aguarde a permissao. Nao use outras ferramentas.", "Precisa de você"),
      ] {
        try await prompt(role, text)
        let banner = app.buttons["session-alert-open"]
        XCTAssertTrue(banner.waitForExistence(timeout: 90), role)
        XCTAssertTrue(banner.label.contains(state))
        screenshot("banner-" + role.lowercased() + "-" + screen)
        app.buttons["Fechar alerta"].tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 8))
      }
    }
    try await prompt("QUESTION", "Use somente question para perguntar: Confirma o exemplo? Cabecalho Exemplo, opcoes Sim e Nao. Aguarde a resposta.")
    let banner = app.buttons["session-alert-open"]
    XCTAssertTrue(banner.waitForExistence(timeout: 90))
    XCTAssertTrue(banner.label.contains("Precisa de você"))
    screenshot("banner-question-sessions")
    banner.tap()
    XCTAssertTrue(app.staticTexts["Onda 7 — pergunta"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.collectionViews["conversation-transcript"].exists)
    screenshot("banner-opened-question")
  }
  func testBannerOpensFromAnotherTabAndPresentedSheet() async throws {
    var app = try launch("PARENT")
    app.buttons["Voltar"].tap()
    app.tabBars.buttons["Painel"].tap()
    try await prompt("SUCCESS", "Responda apenas: Pronto.")
    XCTAssertTrue(app.buttons["session-alert-open"].waitForExistence(timeout: 90))
    screenshot("banner-other-tab")
    app.buttons["session-alert-open"].tap()
    XCTAssertTrue(app.staticTexts["Onda 7 — conclusão"].waitForExistence(timeout: 15))
    app = try launch("PARENT")
    app.buttons["Mais opções"].tap()
    app.buttons["Detalhes da sessão"].tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForExistence(timeout: 10))
    try await prompt("SUCCESS", "Responda apenas: Pronto novamente.")
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline && !app.buttons.matching(identifier: "session-alert-open").allElementsBoundByIndex.contains(where: \.isHittable) {
      try await Task.sleep(for: .milliseconds(250))
    }
    let visible = try XCTUnwrap(app.buttons.matching(identifier: "session-alert-open").allElementsBoundByIndex.first(where: \.isHittable))
    screenshot("banner-over-sheet")
    visible.tap()
    XCTAssertTrue(app.navigationBars["Detalhes da sessão"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Onda 7 — conclusão"].waitForExistence(timeout: 15))
    screenshot("banner-opened-from-sheet")
  }
  func testMuteAndForegroundDoNotReplay() async throws {
    let app = try launch("PARENT")
    _ = try await api("/api/rpc/custom.preferences/mutate", body: ["input": ["type": "sidebar.mute", "session": try id("MUTED"), "muted": true]])
    try await prompt("MUTED", "Responda apenas: Silenciada.")
    try await waitForSuccess("MUTED")
    XCTAssertFalse(app.buttons["session-alert-open"].exists)
    XCUIDevice.shared.press(.home)
    let previous = try await idle("SUCCESS")
    try await prompt("SUCCESS", "Responda apenas: Fora da tela.")
    try await waitForSuccess("SUCCESS", after: previous)
    app.activate()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["session-alert-open"].waitForExistence(timeout: 5))
    screenshot("reconnected-without-replay")
    _ = try await api("/api/rpc/custom.preferences/mutate", body: ["input": ["type": "sidebar.mute", "session": try id("MUTED"), "muted": false]])
  }
  func testMissingDirectoryResolvesModelNameFromDefaultCatalog() throws {
    let app = try launch("MISSING")
    XCTAssertTrue(app.staticTexts["Diretório indisponível"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Luna 6 · low ·'")).firstMatch.waitForExistence(timeout: 20))
    XCTAssertFalse(app.textViews["conversation-composer"].exists)
    screenshot("missing-directory-model-name")
  }
  func testOwnSessionCompletionIsSilentInFullScreenComposer() async throws {
    let app = try launch("PARENT")
    app.buttons["Adicionar"].tap()
    app.buttons["Expandir compositor"].tap()
    XCTAssertTrue(app.navigationBars["Mensagem"].waitForExistence(timeout: 10))
    let previous = try await idle("PARENT")
    try await prompt("PARENT", "Responda apenas: Propria sessao.")
    try await waitForSuccess("PARENT", after: previous)
    XCTAssertFalse(app.buttons["session-alert-open"].waitForExistence(timeout: 3))
    app.buttons["Recolher"].tap()
  }
}
