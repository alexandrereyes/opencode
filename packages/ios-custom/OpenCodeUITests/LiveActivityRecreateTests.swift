import XCTest

/// "Recriar Live Activity" (Você → Apple Watch) with real ActivityKit, the app's own agents driver and a closed
/// in-memory `custom.live-activity` that records every call (`RecreateFixtureRoot`). Whether the watch mirrors the
/// new card is not something the simulator can show.
@MainActor final class LiveActivityRecreateTests: XCTestCase {
  private var app: XCUIApplication!
  private var directory: String!

  private func launch(_ extra: [String] = []) throws {
    let environment = ProcessInfo.processInfo.environment
    let server = try XCTUnwrap(environment["OPENCODE_TEST_SERVER_URL"])
    let url = try XCTUnwrap(URL(string: server))
    guard url.host == "127.0.0.1", ![4096, 4177, 4178, 4179].contains(url.port ?? 0) else {
      throw XCTSkip("Use um sandbox exclusivo.")
    }
    directory = try XCTUnwrap(environment["OPENCODE_CAPTURE_DIR"])
    app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", server, "-OpenCodeAgentsActivityFixture", "state-working",
      "-OpenCodeRecreateFixture", "-OpenCodeRecreateTimeout", "20"] + extra
    app.launch()
    if !app.staticTexts["recreate-report"].waitForExistence(timeout: 15) {
      // The system may have woken the app in the background for an earlier run's Live Activities; the launch then
      // brought that process forward without the fixture arguments (seen once), so start it again.
      app.terminate()
      app.launch()
    }
    XCTAssertTrue(app.staticTexts["recreate-report"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["debug-server-url"].label, server)
  }

  /// The report once it contains `expected`: `agentes=N [id:token] voz=N` and the calls, one per line.
  private func report(_ expected: String, timeout: TimeInterval = 15) -> String {
    let deadline = Date.now.addingTimeInterval(timeout)
    repeat {
      app.buttons["Ler atividades"].tap()
      let value = app.staticTexts["recreate-report"].label
      if value.contains(expected) { return value }
    } while Date.now < deadline
    XCTFail("O relatório não chegou a \(expected)")
    return app.staticTexts["recreate-report"].label
  }

  private func ids(_ report: String) -> [String] {
    let first = report.components(separatedBy: "\n").first ?? ""
    return first.components(separatedBy: "[").dropFirst().compactMap { $0.components(separatedBy: ":").first }
  }

  private func save(_ name: String) throws {
    try XCUIScreen.main.screenshot().pngRepresentation.write(to:
      URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }

  private func message(_ prefix: String) -> String {
    let text = app.staticTexts["watch-recreate-message"]
    XCTAssertTrue(text.waitForExistence(timeout: 40))
    XCTAssertTrue(text.label.hasPrefix(prefix), text.label)
    return text.label
  }

  /// The simulator either gives Live Activities push tokens (a signed build) or not; each path is the real one for it.
  func testRecreateReplacesTheAgentsActivityOnceAndKeepsVoice() throws {
    try launch()
    let initial = report("agentes=1 [")
    let old = try XCTUnwrap(ids(initial).first)
    XCTAssertTrue(initial.contains("voz=1"))
    try save("01-antes")
    let tokens = report(":token]", timeout: 10).contains("[\(old):token]")
    let button = app.buttons["watch-recreate-activity"]
    button.tap()
    // A second tap while it runs does nothing: the button is disabled.
    if button.isEnabled == false { try save("02-recriando") }
    button.tap()
    guard tokens else {
      // Without a token the new activity can never be registered: it goes and the old one stays, unreported.
      _ = message("O iOS não")
      let after = report("agentes=1 [")
      XCTAssertEqual(ids(after), [old])
      XCTAssertFalse(after.contains("ended \(old)"))
      XCTAssertTrue(after.contains("voz=1"))
      try save("03-sem-token")
      return
    }
    _ = message("Atividade recriada.")
    let after = report("ended \(old) ended")
    let current = ids(after)
    XCTAssertEqual(current.count, 1, after)
    let new = try XCTUnwrap(current.first)
    XCTAssertNotEqual(new, old)
    let lines = after.components(separatedBy: "\n")
    let registered = try XCTUnwrap(lines.firstIndex(of: "activity \(new)"), after)
    let ended = try XCTUnwrap(lines.firstIndex(of: "ended \(old) ended"), after)
    XCTAssertLessThan(registered, ended, "a nova é registrada antes de a antiga terminar")
    // The old token is never registered again once the new one is: the server must not point back at it.
    XCTAssertFalse(lines[registered...].contains("activity \(old)"), after)
    XCTAssertEqual(lines.filter { $0 == "activity \(new)" }.count, 1, after)
    XCTAssertFalse(after.contains("dismissed") || after.contains("unregister"), after)
    XCTAssertTrue(after.contains("voz=1"))
    try save("03-recriada")
  }

  func testRefusedRegistrationKeepsTheOldActivity() throws {
    try launch(["-OpenCodeRecreateFail", "register"])
    let initial = report("agentes=1 [")
    let old = try XCTUnwrap(ids(initial).first)
    guard report(":token]", timeout: 10).contains("[\(old):token]") else {
      throw XCTSkip("Este simulador não entrega token de Live Activity; o caminho sem token está no outro teste.")
    }
    app.buttons["watch-recreate-activity"].tap()
    _ = message("O servidor não confirmou")
    let after = report("recusada")
    XCTAssertEqual(ids(after), [old], after)
    let lines = after.components(separatedBy: "\n")
    let refused = try XCTUnwrap(lines.firstIndex { $0.hasSuffix("recusada") }, after)
    // Pointed back at the old activity after the refusal; the old one never ends.
    XCTAssertNotNil(lines[refused...].firstIndex(of: "activity \(old)"), after)
    XCTAssertFalse(after.contains("ended \(old)") || after.contains("dismissed"), after)
    try save("04-recusada")
  }
}
