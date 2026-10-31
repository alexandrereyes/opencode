import XCTest

@MainActor final class ConversationFollowTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  func testEmptyTailRestorationCompletes() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
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
        "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
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

  /// Opened at the end, the last answer's footer is whole on screen, even though some of its rows settle their
  /// height after the first frame.
  func testOpeningAtTheEndShowsTheLastFooterWhole() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
        "-OpenCodeTheme", theme, "-OpenCodeFixturePosition", "tail",
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      RunLoop.current.run(until: Date().addingTimeInterval(1.5))
      let footers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'read-aloud-message-'"))
        .allElementsBoundByIndex.map(\.frame).filter { $0.minY < transcript.frame.maxY }
      let last = try XCTUnwrap(footers.max { $0.maxY < $1.maxY })
      XCTAssertLessThanOrEqual(last.maxY, transcript.frame.maxY + 0.5, "the last footer is cut at \(last) in \(transcript.frame)")
      XCTAssertFalse(app.buttons["Ir para a mais recente"].exists)
      // The keyboard shrinks the viewport from the end: the end stays in view, like any chat.
      let cells = transcript.cells.allElementsBoundByIndex.filter { $0.frame.minY < transcript.frame.maxY }
      let end = try XCTUnwrap(cells.max { $0.frame.maxY < $1.frame.maxY }?.identifier)
      app.textViews["conversation-composer"].tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      let keyboard = app.keyboards.firstMatch.frame
      let raised = transcript.cells[end].frame
      XCTAssertLessThan(transcript.frame.maxY, keyboard.minY + 0.5)
      XCTAssertLessThanOrEqual(raised.maxY, transcript.frame.maxY + 0.5, "the end \(raised) is below \(transcript.frame)")
      XCTAssertGreaterThan(raised.maxY, transcript.frame.maxY - 30, "the end \(raised) left the bottom of \(transcript.frame)")
      XCTAssertFalse(app.buttons["Ir para a mais recente"].exists)
      app.terminate()
    }
  }

  /// Growth never scrolls the transcript, not even at the end: the offset stays put while the content grows,
  /// and ↓ appears for what is now below.
  func testGrowthNeverMovesTheScreenInBothThemes() throws {
    for theme in ["openchamber-dark", "openchamber-light"] {
      let app = XCUIApplication()
      app.launchArguments = [
        "-OpenCodeServerURL", TestSandbox.url, "-OpenCodeScrollFixture", "conversation",
        "-OpenCodeTheme", theme, "-OpenCodeFixturePosition", "tail", "-OpenCodeFixtureFollow",
      ]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 20))
      let ready = expectation(for: NSPredicate(format: "value != 'Restaurando leitura'"), evaluatedWith: transcript)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
      let driver = app.buttons["follow-fixture"]
      XCTAssertTrue(driver.waitForExistence(timeout: 5))
      let end = app.buttons["Ir para a mais recente"]
      for cycle in 0..<2 {
        if cycle > 0 {
          XCTAssertTrue(end.waitForExistence(timeout: 5))
          end.tap()
          let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: end)
          XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        }
        driver.tap()
        let finished = expectation(for: NSPredicate(format: "value BEGINSWITH '{'"), evaluatedWith: driver)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        let json = try XCTUnwrap(driver.value as? String)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        XCTAssertGreaterThan(try XCTUnwrap(report["samples"]), 30)
        XCTAssertGreaterThan(try XCTUnwrap(report["heightChanges"]), 10, json)
        XCTAssertEqual(try XCTUnwrap(report["advance"]), 0, accuracy: 0.5, json)
        XCTAssertEqual(try XCTUnwrap(report["backward"]), 0, accuracy: 0.5, json)
        XCTAssertEqual(try XCTUnwrap(report["forward"]), 0, accuracy: 0.5, json)
        XCTAssertGreaterThan(try XCTUnwrap(report["below"]), 24, json)
        XCTAssertTrue(end.waitForExistence(timeout: 5), "the content grown below the viewport offers ↓")
        let attachment = XCTAttachment(string: json)
        attachment.name = "growth-still-\(cycle)-" + theme
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
      "-OpenCodeServerURL", TestSandbox.url,
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
      let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-'")).firstMatch
      if group.exists && group.value as? String == "Recolhido" { group.tap() }
      let child = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
      XCTAssertTrue(child.waitForExistence(timeout: 10))
      child.tap()
      XCTAssertTrue(app.buttons["subagent-badge"].waitForExistence(timeout: 15))
      var request = URLRequest(url: URL(string: TestSandbox.url + "/api/session/" + id + "/prompt")!)
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
      active.url = URL(string: TestSandbox.url + "/api/session/active")
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
      // Opened from the parent's transcript: Back returns to it.
      app.buttons["conversation-back"].tap()
      XCTAssertTrue(list.waitForExistence(timeout: 15))
    }
    app.terminate()
  }
}
