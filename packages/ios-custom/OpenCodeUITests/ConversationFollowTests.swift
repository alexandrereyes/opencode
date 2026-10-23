import XCTest

@MainActor final class ConversationFollowTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testEmptyTailRestorationCompletes() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollFixture", "conversation",
      "-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureEmpty",
      "-OpenCodeTheme", ProcessInfo.processInfo.environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 20))
    let ready = expectation(for: NSPredicate(format: "value == '0 mensagens carregadas'"), evaluatedWith: transcript)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    XCTAssertTrue(app.textViews["conversation-composer"].exists)
    app.terminate()
  }

  func testHistoryJumpToLatestInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollFixture", "conversation",
        "-OpenCodeFixturePosition", "middle", "-OpenCodeTheme", theme,
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      let latest = app.buttons["Ir para a mais recente"]
      XCTAssertTrue(latest.waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["Ir às novas mensagens"].exists)
      XCTAssertFalse(app.staticTexts["Novas mensagens"].exists)
      latest.tap()
      let restored = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 20), .completed)
      let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: latest)
      XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 15), .completed)
      app.terminate()
    }
  }

  func testHeightChangesFollowMonotonicallyInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollFixture", "conversation",
        "-OpenCodeTheme", theme, "-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureFollow", "-OpenCodeScrollDiagnostics",
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      let driver = app.buttons["follow-fixture"]
      XCTAssertTrue(driver.waitForExistence(timeout: 5))
      for cycle in 0..<2 {
        if cycle > 0 {
          for _ in 0..<3 { transcript.swipeDown(velocity: .slow) }
          let end = app.buttons["Ir para a mais recente"]
          XCTAssertTrue(end.waitForExistence(timeout: 5))
          end.tap()
          RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        driver.tap()
        let finished = expectation(for: NSPredicate(format: "value BEGINSWITH '{'"), evaluatedWith: driver)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        let json = try XCTUnwrap(driver.value as? String)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        XCTAssertGreaterThan(try XCTUnwrap(report["samples"]), 30)
        XCTAssertGreaterThan(try XCTUnwrap(report["heightChanges"]), 10)
        XCTAssertGreaterThan(try XCTUnwrap(report["advance"]), 500)
        XCTAssertEqual(try XCTUnwrap(report["backward"]), 0, accuracy: 0.5, json)
        XCTAssertEqual(try XCTUnwrap(report["gap"]), 0, accuracy: 2, json)
        XCTAssertEqual(report["animations"], Double(cycle), json)
        let attachment = XCTAttachment(string: json)
        attachment.name = "follow-height-changes-\(cycle)-" + theme
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      app.terminate()
    }
  }

  func testLiveChildReplay() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["OPENCODE_FOLLOW_LIVE"] == "1" else { throw XCTSkip("Explicit live replay only") }
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeScrollDiagnostics",
      "-OpenCodeTheme", environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark",
      "-OpenCodeOpenSession", try XCTUnwrap(environment["OPENCODE_FOLLOW_PARENT"]),
    ]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launch()
    let list = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(list.waitForExistence(timeout: 25))
    let settled = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: list)
    XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 25), .completed)
    for role in ["A", "B"] {
      let id = try XCTUnwrap(environment["OPENCODE_FOLLOW_CHILD_" + role])
      let title = try XCTUnwrap(environment["OPENCODE_FOLLOW_TITLE_" + role])
      for _ in 0..<7 { list.swipeDown(velocity: .fast) }
      let child = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
      XCTAssertTrue(child.waitForExistence(timeout: 10))
      child.tap()
      XCTAssertTrue(app.buttons["Voltar à sessão principal"].waitForExistence(timeout: 15))
      var request = URLRequest(url: URL(string: "http://127.0.0.1:4177/api/session/" + id + "/prompt")!)
      request.httpMethod = "POST"
      request.setValue("Basic " + Data(("opencode:" + (environment["OPENCODE_TEST_PASSWORD"] ?? "")).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        "text": "Scroll replay: 4 separate read-only shell pwd calls with brief progress, then a synthetic 24-line numbered checklist. No changes or network.",
      ])
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
      list.swipeDown(velocity: .slow)
      list.swipeUp(velocity: .slow)
      if app.buttons["Ir para a mais recente"].waitForExistence(timeout: 4) { app.buttons["Ir para a mais recente"].tap() }
      try await Task.sleep(for: .seconds(12))
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "live-child-" + role
      capture.lifetime = .keepAlways
      add(capture)
      var active = request
      active.url = URL(string: "http://127.0.0.1:4177/api/session/active")
      active.httpMethod = "GET"
      active.httpBody = nil
      for attempt in 0..<120 {
        let (data, _) = try await URLSession.shared.data(for: active)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(envelope["data"] as? [String: Any])
        if sessions[id] == nil { break }
        XCTAssertLessThan(attempt, 119, "The owned replay child must finish before leaving the test")
        try await Task.sleep(for: .milliseconds(500))
      }
      app.buttons["Voltar à sessão principal"].tap()
      XCTAssertTrue(list.waitForExistence(timeout: 15))
    }
    app.terminate()
  }
}
