import XCTest

/// Progresso while the work the session started goes on (rev. 2026-11-02), server-free: the conversation fixture
/// ends with a completed `todowrite` (3 of 7) and the session itself is idle. A background subagent still working
/// (`-OpenCodeFixtureFamilyWorking`) keeps the pill and its list; with nothing working, or every item finished, there
/// is none. Run with `script/test-subscriptions.py OpenCodeUITests/ProgressFamilyTests` and an explicit sandbox.
@MainActor final class ProgressFamilyTests: XCTestCase {
  private static let current = "Atualizar a Live Activity e o relógio"
  private let app = XCUIApplication()
  override func setUp() { continueAfterFailure = false }

  func testTheListStaysWhileASubagentWorksAndNotOtherwise() throws {
    let pill = app.buttons["conversation-progress"]
    // The session is idle while its subagent works: the list it planned stays, and opens.
    try launch(["-OpenCodeFixtureProgress", "open", "-OpenCodeFixtureFamilyWorking"])
    XCTAssertTrue(pill.waitForExistence(timeout: 15))
    XCTAssertEqual(pill.label, "Progresso: 3 de 7. Agora: \(Self.current)")
    capture("familia-trabalhando")
    pill.tap()
    let item = app.descendants(matching: .any)["conversation-progress-item-3"]
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    XCTAssertEqual(item.label, "Em andamento: \(Self.current)")
    XCTAssertEqual(app.descendants(matching: .any)["conversation-progress-item-6"].label, "Cancelada: Migrar as fixtures antigas")
    capture("familia-trabalhando-lista")
    app.terminate()

    // Nothing works any more: no pill.
    try launch(["-OpenCodeFixtureProgress", "open"])
    XCTAssertFalse(pill.waitForExistence(timeout: 5))
    capture("familia-parada")
    app.terminate()

    // Every item finished: no pill, though the subagent still works.
    try launch(["-OpenCodeFixtureProgress", "closed", "-OpenCodeFixtureFamilyWorking"])
    XCTAssertFalse(pill.waitForExistence(timeout: 5))
    capture("lista-fechada")
    app.terminate()
  }

  private func launch(_ extra: [String]) throws {
    let environment = ProcessInfo.processInfo.environment
    app.launchArguments = ["-OpenCodeServerURL", try XCTUnwrap(environment["OPENCODE_TEST_SERVER_URL"]),
      "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
      "-OpenCodeScrollFixture", "conversation", "-OpenCodeFixturePosition", "tail"] + extra
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "progresso-" + name + "-" + (ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
