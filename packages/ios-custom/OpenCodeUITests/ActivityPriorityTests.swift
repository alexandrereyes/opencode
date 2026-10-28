import XCTest

@MainActor final class ActivityPriorityTests: XCTestCase {
  func testVoiceKeepsPriorityAndAgentsSurvive() throws {
    let environment = ProcessInfo.processInfo.environment
    let server = try XCTUnwrap(environment["OPENCODE_TEST_SERVER_URL"])
    let url = try XCTUnwrap(URL(string: server))
    guard url.host == "127.0.0.1", ![4096, 4177, 4178].contains(url.port ?? 0) else {
      throw XCTSkip("Use um sandbox exclusivo.")
    }
    let directory = try XCTUnwrap(environment["OPENCODE_CAPTURE_DIR"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", server, "-OpenCodeAgentsActivityFixture", "state-working",
      "-OpenCodeActivityPriorityFixture"]
    app.launch()
    XCTAssertTrue(app.staticTexts["debug-server-url"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["debug-server-url"].label, server)

    func report(_ expected: String) throws -> String {
      let deadline = Date.now.addingTimeInterval(10)
      repeat {
        app.buttons["Ler atividades"].tap()
        let value = app.staticTexts["activity-priority-report"].label
        if value.contains(expected) { return value }
      } while Date.now < deadline
      XCTFail("ActivityKit não chegou a \(expected)")
      return app.staticTexts["activity-priority-report"].label
    }
    func save(_ name: String) throws {
      try XCUIScreen.main.screenshot().pngRepresentation.write(to:
        URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
    func surfaces(_ name: String) throws {
      XCUIDevice.shared.press(.home)
      let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      // SpringBoard animates the compact/expanded and Lock Screen presentations asynchronously.
      sleep(2)
      try save("\(name)-compact")
      system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).press(forDuration: 1)
      sleep(2)
      try save("\(name)-expanded")
      system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
      system.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.001)).press(forDuration: 0.1,
        thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)))
      sleep(4)
      for label in ["Permitir", "Permitir Sempre", "Allow", "Always Allow"] where system.buttons[label].exists {
        system.buttons[label].tap()
      }
      try save("\(name)-lock")
      system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)).press(forDuration: 0.1,
        thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
      app.activate()
      XCTAssertTrue(app.buttons["Ler atividades"].waitForExistence(timeout: 10))
    }

    let initial = try report("agentes=50")
    let identity = try XCTUnwrap(initial.components(separatedBy: "id=").last?.components(separatedBy: " ").first)
    try surfaces("01-agentes")
    app.buttons["Iniciar voz"].tap()
    _ = try report("voz=100 Ouvindo")
    try save("02-relevancia")
    try surfaces("02-voz")
    app.buttons["Atualizar agentes"].tap()
    XCTAssertTrue(try report("progresso=1").contains("voz=100"))
    try surfaces("03-agentes-atualizados")
    for (button, label) in [("Reconectar", "Reconectando…"), ("Sem conexão", "Sem conexão"), ("Retomar", "Ouvindo")] {
      app.buttons[button].tap()
      XCTAssertTrue(try report("voz=100 \(label)").contains("id=\(identity)"))
    }
    app.buttons["Silenciar"].tap()
    _ = try report("voz=100")
    try save("04-recuperacao")
    app.buttons["Encerrar voz"].tap()
    let ended = try report("agentes=50")
    XCTAssertFalse(ended.contains("voz="))
    XCTAssertTrue(ended.contains("id=\(identity) progresso=1"))
    try save("05-relevancia-final")
    try surfaces("05-agentes-retomados")
  }
}
