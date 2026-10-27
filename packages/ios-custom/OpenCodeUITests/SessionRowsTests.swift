import XCTest

/// These checks read the sandbox list and never touch its pending requests.
@MainActor final class SessionRowsTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + (environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark")
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testMainAttentionPinnedAndArchivedDirectoryLabels() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme",
      environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(
      environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    let waiting = app.buttons["session-section-attention"]
    XCTAssertTrue(waiting.waitForExistence(timeout: 25))
    XCTAssertTrue(waiting.label.hasPrefix("Precisa de você, "))
    XCTAssertTrue(app.buttons["Permitir"].exists)
    XCTAssertTrue(app.buttons["Negar"].exists)
    XCTAssertFalse(app.buttons["Responder"].exists)
    // The column header replaces the navigation bar: no "…" menu, title beside voice and Nova sessão.
    XCTAssertFalse(app.buttons["Mais opções"].exists)
    XCTAssertEqual(app.sessionsTitle.frame.midY, app.buttons["Nova sessão"].frame.midY, accuracy: 12)
    let metadata = app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH 'Diretório ' AND label CONTAINS ', branch '"))
    XCTAssertTrue(metadata.firstMatch.waitForExistence(timeout: 20))
    shot("sessions-main-attention")
    let pinned = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Alternativas Linear open source,'")
    ).firstMatch
    app.revealSessionRow(pinned)
    XCTAssertTrue(pinned.label.contains("branch neon-mountain"))
    XCTAssertTrue(pinned.label.contains("há ") || pinned.label.contains("Agora mesmo"))
    XCTAssertFalse(pinned.label.contains("Ontem"))
    shot("sessions-main-pinned")
    // "Arquivadas N" is the last row, after "Anteriores".
    let archives = app.buttons["sessions-archived"]
    app.revealSessionRow(archives)
    archives.tap()
    XCTAssertTrue(app.navigationBars["Arquivadas"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Diretório '"))
        .firstMatch.waitForExistence(timeout: 10))
    shot("sessions-archived")
    app.buttons["Concluir"].tap()
    // Concurrent test histories can put these rows over a hundred entries below the top.
    // Use the existing project filters rather than extending the row-finder's time budget.
    selectProject("ios-conversation", in: app)
    let root = app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Conversa C — histórico e compositor,'")
    ).firstMatch
    app.revealSessionRow(root)
    XCTAssertTrue(root.label.contains("branch neon-mountain"))
    XCTAssertTrue(root.label.contains("Diretório …/repos/ios-conversation"))
    XCTAssertFalse(root.label.contains("/private/var/folders/"))
    shot("sessions-main-root")
    selectProject("abacato-v2", in: app)
    let long = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Redesign,'")).firstMatch
    app.revealSessionRow(long)
    XCTAssertTrue(long.label.contains("branch feat/redesign-identidade"))
    shot("sessions-main-long-path-branch")
  }

  private func selectProject(_ name: String, in app: XCUIApplication) {
    let all = app.buttons["Todas"]
    for _ in 0..<40 {
      if all.isHittable { break }
      app.collectionViews.firstMatch.swipeDown(velocity: .fast)
    }
    all.tap()
    let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    for _ in 0..<8 {
      if project.isHittable { break }
      app.scrollViews.firstMatch.swipeLeft(velocity: .fast)
    }
    XCTAssertTrue(project.isHittable)
    project.tap()
  }
}
