import XCTest

@MainActor final class AgentSelectionTests: XCTestCase {
  func testRepeatedSendsAndOnePickerChange() async throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let id = try XCTUnwrap(environment["OPENCODE_TEST_AGENT_SESSION"])
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", "http://127.0.0.1:4177",
      "-OpenCodeOpenSession", id, "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark"]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = password
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    for index in 0..<4 {
      if index == 3 {
        app.buttons["agent-picker"].tap()
        let agent = app.buttons["utra"]
        XCTAssertTrue(agent.waitForExistence(timeout: 10))
        agent.tap()
      }
      let composer = app.textViews["conversation-composer"]
      composer.tap()
      composer.typeText("Responda apenas OK, sem ferramentas. \(index)")
      app.buttons["Enviar mensagem"].tap()
      XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == ''"), object: composer)], timeout: 30), .completed)
      let messages = try await messages(id, password: password)
      XCTAssertEqual(messages.filter { $0.type == "agent-switched" }.count, index == 3 ? 1 : 0)
      XCTAssertEqual(messages.filter { $0.type == "model-switched" }.count, 0)
      try await waitForIdle(id, password: password)
    }
    let switches = try await messages(id, password: password).filter { $0.type == "agent-switched" }
    XCTAssertEqual(switches.first?.agent, "utra")
    XCTAssertEqual(switches.first?.previous, "build")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private struct Message: Decodable {
    let type: String
    let agent: String?
    let previous: String?
  }
  private func waitForIdle(_ id: String, password: String) async throws {
    struct Active: Decodable { let data: [String: State] }
    struct State: Decodable { let type: String }
    for _ in 0..<240 {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:4177/api/session/active")!)
      request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
      let (data, _) = try await URLSession.shared.data(for: request)
      if try JSONDecoder().decode(Active.self, from: data).data[id] == nil { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTFail("A sessão de teste deve terminar a execução")
  }
  private func messages(_ id: String, password: String) async throws -> [Message] {
    struct Page: Decodable { let data: [Message] }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:4177/api/session/\(id)/message?limit=100")!)
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return try JSONDecoder().decode(Page.self, from: data).data
  }
}
