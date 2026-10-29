import XCTest

/// "Você → Dados do iPhone" and a real Sessão mestra `iphone_query` round trip against an isolated sandbox.
/// Grant location to the simulator beforehand (`simctl privacy … grant location`) and set its position.
@MainActor final class DeviceDataTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  private func launch() throws -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    return app
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "device-data-" + name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func request(_ path: String, body: Data? = nil) async throws -> Data {
    var request = URLRequest(url: URL(string: TestSandbox.url + path)!)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return data
  }
  private func openDeviceData(_ app: XCUIApplication) {
    XCTAssertTrue(app.accountButton.waitForExistence(timeout: 30))
    app.openYou()
    XCTAssertTrue(app.navigationBars["Você"].waitForExistence(timeout: 10))
    let row = app.descendants(matching: .any)["settings-device-data"].firstMatch
    for _ in 0..<8 where !(row.exists && row.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    row.tap()
    XCTAssertTrue(app.navigationBars["Dados do iPhone"].waitForExistence(timeout: 10))
  }

  func testSourcesScreenShowsEachSourceAndEnablesLocation() throws {
    let app = try launch()
    defer { app.terminate() }
    openDeviceData(app)
    let connection = app.descendants(matching: .any)["device-data-connection"].firstMatch
    XCTAssertTrue(connection.waitForExistence(timeout: 10))
    XCTAssertTrue(NSPredicate(format: "label CONTAINS 'Conectado'").evaluate(with: connection)
      || connection.waitForLabel(containing: "Conectado", timeout: 20))
    let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Os agentes do OpenCode leem estes dados'")).firstMatch
    XCTAssertTrue(footer.waitForExistence(timeout: 5))
    XCTAssertFalse(footer.label.contains("mestra"))
    for source in ["device", "network", "location", "health", "motion", "photos"] {
      let toggle = app.switches["device-source-" + source]
      for _ in 0..<6 where !(toggle.exists && toggle.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
      XCTAssertTrue(toggle.exists, source)
    }
    app.collectionViews.firstMatch.swipeDown(velocity: .fast)
    XCTAssertEqual(app.switches["device-source-device"].value as? String, "1")
    XCTAssertEqual(app.switches["device-source-network"].value as? String, "1")
    let location = app.switches["device-source-location"]
    if location.value as? String != "1" { location.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
    XCTAssertTrue(app.staticTexts["device-source-status-location"].waitForLabel(containing: "Permitido", timeout: 15))
    shot("sources")
  }

  func testMasterReadsDeviceNetworkAndLocationFromTheApp() async throws {
    let app = try launch()
    defer { app.terminate() }
    openDeviceData(app)
    let location = app.switches["device-source-location"]
    if location.value as? String != "1" { location.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
    XCTAssertTrue(app.staticTexts["device-source-status-location"].waitForLabel(containing: "Permitido", timeout: 15))
    app.showSessions()
    let accessory = app.buttons["master-accessory"]
    XCTAssertTrue(accessory.waitForExistence(timeout: 30))
    accessory.tap()
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 20))
    input.tap()
    let token = "dados-" + UUID().uuidString.prefix(8)
    input.typeText("Use a ferramenta iphone_query três vezes, com source device, network e location, e responda numa linha com a bateria, o tipo de rede e a cidade. (\(token))")
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.buttons["master-trash"].waitForExistence(timeout: 60))
    struct Profile: Decodable {
      let output: Output
      struct Output: Decodable { let data: Data }
      struct Data: Decodable { let masterSessions: [String: String] }
    }
    let profile = try JSONDecoder().decode(Profile.self, from: await request("/api/rpc/custom.preferences/get", body: Data(#"{"input":{}}"#.utf8)))
    let id = try XCTUnwrap(profile.output.data.masterSessions["local"])
    var answered: [String: String] = [:]
    for _ in 0..<90 {
      let page = try JSONSerialization.jsonObject(with: await request("/api/session/" + id + "/message?limit=50")) as? [String: Any]
      // Newest first: only the replies after this run's prompt count.
      let messages = page?["data"] as? [[String: Any]] ?? []
      let prompt = messages.firstIndex { ($0["text"] as? String)?.contains(token) == true } ?? 0
      let parts = messages[..<prompt].flatMap { $0["content"] as? [[String: Any]] ?? [] }
      for part in parts where part["type"] as? String == "tool" && part["name"] as? String == "iphone_query" {
        let state = part["state"] as? [String: Any]
        guard state?["status"] as? String == "completed", let source = (state?["input"] as? [String: Any])?["source"] as? String,
          let text = (state?["content"] as? [[String: Any]])?.first?["text"] as? String,
          let output = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
        answered[source] = output["status"] as? String
      }
      if Set(answered.keys).isSuperset(of: ["device", "network", "location"]) { break }
      try await Task.sleep(for: .seconds(2))
    }
    XCTAssertEqual(answered["device"], "ok")
    XCTAssertEqual(answered["network"], "ok")
    XCTAssertEqual(answered["location"], "ok")
    let summary = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Consultou o iPhone'")).firstMatch
    XCTAssertTrue(summary.waitForExistence(timeout: 30))
    shot("master")
  }
}

private extension XCUIElement {
  func waitForLabel(containing text: String, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: self)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }
}
