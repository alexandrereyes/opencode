import XCTest

/// An open conversation acknowledges answers only while it is seen (`ReadVisibility.phone`): with the app in the
/// background an answer stays unread, coming back to the foreground acknowledges it without reopening, and the
/// Sessões list acknowledges nothing. `script/test-read-visibility.py` prepares an owned session whose model is a
/// local fake that answers "ok" (`OPENCODE_READ_SESSION`, `OPENCODE_READ_PROVIDER`, `OPENCODE_READ_MODEL`).
@MainActor final class ReadVisibilityTests: XCTestCase {
  private struct SessionEnvelope: Decodable {
    struct Info: Decodable {
      struct Time: Decodable { let idle: Double?; let viewed: Double? }
      let time: Time
    }
    let data: Info
  }
  private struct ActiveEnvelope: Decodable {
    let data: [String: AnyDecodable]
  }
  private struct AnyDecodable: Decodable {}
  private struct Prompt: Encodable {
    struct Model: Encodable { let providerID: String; let id: String }
    let text = "Responda apenas: ok"
    let agent = "build"
    let model: Model
  }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }

  func testAnswersStayUnreadUntilTheConversationIsSeen() async throws {
    let id = try XCTUnwrap(environment["OPENCODE_READ_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeOpenSession", id,
      "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    try app.requireSandbox()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    // Seen: an answer arriving with the conversation on screen is acknowledged.
    try await answer(id)
    try await expectViewed(id, true, "Uma resposta com a conversa na tela é lida")
    screenshot(app, "1-visivel-lida")

    // In the background: the conversation stays open, its answer stays unread.
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 10)
      || app.wait(for: .runningBackground, timeout: 1))
    try await answer(id)
    try await Task.sleep(for: .seconds(3))
    try await expectViewed(id, false, "Com o app em segundo plano a resposta continua não lida")

    // Back in the foreground, the same conversation acknowledges it without being reopened.
    app.activate()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 20))
    try await expectViewed(id, true, "Voltar ao app com a conversa aberta lê a resposta")
    screenshot(app, "2-de-volta-lida")

    // On the Sessões list nothing acknowledges a newer answer.
    app.showSessions()
    try await answer(id)
    try await Task.sleep(for: .seconds(3))
    try await expectViewed(id, false, "Na lista de Sessões a resposta nova continua não lida")
    screenshot(app, "3-lista-nao-lida")
  }

  private func answer(_ id: String) async throws {
    let before = try await session(id).time.idle ?? 0
    let model = Prompt.Model(
      providerID: try XCTUnwrap(environment["OPENCODE_READ_PROVIDER"]), id: try XCTUnwrap(environment["OPENCODE_READ_MODEL"]))
    _ = try await request("/api/session/" + id + "/prompt", body: try JSONEncoder().encode(Prompt(model: model)))
    for _ in 0..<240 {
      let active = try JSONDecoder().decode(ActiveEnvelope.self, from: await request("/api/session/active"))
      if active.data[id] == nil, try await session(id).time.idle ?? 0 > before { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTFail("A resposta falsa deve terminar")
  }

  private func expectViewed(_ id: String, _ expected: Bool, _ message: String) async throws {
    for _ in 0..<(expected ? 100 : 1) {
      let time = try await session(id).time
      if (time.idle != nil && time.idle == time.viewed) == expected { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail(message)
  }

  private func session(_ id: String) async throws -> SessionEnvelope.Info {
    try JSONDecoder().decode(SessionEnvelope.self, from: await request("/api/session/" + id)).data
  }

  private func request(_ path: String, body: Data? = nil) async throws -> Data {
    var request = URLRequest(url: URL(string: TestSandbox.url + path)!)
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
    return data
  }

  private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
