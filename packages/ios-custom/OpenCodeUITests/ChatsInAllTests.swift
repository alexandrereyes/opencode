import XCTest

/// Needs a sandbox with imported chats: `OPENCODE_TEST_CHAT_READ`, `_UNREAD` and `_RUN` are chat session IDs
/// (`_RUN` runs briefly during the test, with one Luna 6 / low shell sleep), `OPENCODE_TEST_CHAT_TITLE` the read
/// chat's title, `OPENCODE_TEST_CHAT_PROJECT_ROW` a repository session ID, and `OPENCODE_TEST_CHAT_COLOR` /
/// `OPENCODE_TEST_AVATAR_ARC` the theme's `chatAvatar` and `success` colors.
@MainActor final class ChatsInAllTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testAllMixesChatsWithTheSharedChatAvatarAndTheChatsFilterKeepsTheirOwn() throws {
    continueAfterFailure = false
    let read = try value("CHAT_READ")
    let unread = try value("CHAT_UNREAD")
    let run = try value("CHAT_RUN")
    let title = try value("CHAT_TITLE")
    let project = try value("CHAT_PROJECT_ROW")
    let color = try value("CHAT_COLOR")
    let arc = try value("AVATAR_ARC")
    let password = try value("PASSWORD")
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = password
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 20))
    try app.requireSandbox()
    app.showSessions()
    XCTAssertTrue(app.sessionsTitle.waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["filter-all"].isSelected)

    // "Todas" lists every chat among the day sections, with the chat avatar and "Chats" as the second line.
    let chat = row(read, app)
    app.revealSessionRow(chat)
    XCTAssertTrue(chat.label.contains(", Chats"), chat.label)
    let shared = chat.pixels(near: color, leading: 70)
    XCTAssertGreaterThan(shared, 200, "Chat avatar in Todas")
    let other = row(unread, app)
    app.revealSessionRow(other)
    XCTAssertTrue(other.label.contains(", Chats") && other.label.contains(", não lida"), other.label)
    XCTAssertGreaterThan(other.pixels(near: color, leading: 70), 200, "Chat avatar on an unread chat")
    let repository = row(project, app)
    app.revealSessionRow(repository)
    XCTAssertFalse(repository.label.contains(", Chats"))
    XCTAssertLessThan(repository.pixels(near: color, leading: 70), 20, "A repository keeps its own avatar")
    app.revealSessionRow(other)
    shot("chats-all")

    // Running: the green arc goes around the chat avatar, in Trabalhando.
    try prompt(run, password: password)
    let running = row(run, app)
    XCTAssertTrue(wait({ app.revealSessionRow(running); return running.pixels(near: arc, leading: 70) > 5 }, 60),
      "Running arc around the chat avatar")
    XCTAssertGreaterThan(running.pixels(near: color, leading: 70), 100)
    shot("chats-all-running")

    // Batch selection adds its circle before the avatar, which stays.
    app.revealSessionRow(chat)
    chat.press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Selecionar"].waitForExistence(timeout: 5))
    app.buttons["Selecionar"].tap()
    XCTAssertTrue(app.buttons["sessions-selection-done"].waitForExistence(timeout: 5))
    XCTAssertTrue(chat.isSelected)
    XCTAssertGreaterThan(chat.pixels(near: color, leading: 110), 200, "Chat avatar during selection")
    shot("chats-all-selection")
    app.buttons["sessions-selection-done"].tap()
    XCTAssertTrue(app.buttons["sessions-selection-done"].waitForNonExistence(timeout: 5))

    // The Chats chip keeps each chat's own avatar and no second line. The chips scroll away with the list.
    let filter = app.buttons["filter-chats"]
    for _ in 0..<8 where !filter.isHittable { app.swipeDown(velocity: .fast) }
    filter.tap()
    app.revealSessionRow(chat)
    XCTAssertTrue(wait({ !chat.label.contains(", Chats") }, 10), chat.label)
    XCTAssertLessThan(chat.pixels(near: color, leading: 70), shared / 4, "Own avatar under the Chats chip")
    shot("chats-filter")

    // The session switcher mixes chats with repository sessions, so it uses the chat avatar.
    chat.tap()
    let trigger = app.buttons["conversation-switcher"]
    XCTAssertTrue(trigger.waitForExistence(timeout: 30))
    trigger.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText(title)
    let switched = app.buttons["switcher-row-" + read]
    XCTAssertTrue(switched.waitForExistence(timeout: 10))
    XCTAssertTrue(switched.label.contains(", Chats"), switched.label)
    XCTAssertGreaterThan(switched.pixels(near: color, leading: 70), 100, "Chat avatar in the switcher")
    shot("chats-switcher")
  }

  private func value(_ name: String) throws -> String {
    try XCTUnwrap(environment["OPENCODE_TEST_" + name], name)
  }
  private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(identifier: "session-row-" + id).firstMatch
  }
  private func wait(_ condition: @escaping () -> Bool, _ timeout: TimeInterval = 15) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  /// One foreground shell sleep, so the chat stays running for a while.
  private func prompt(_ session: String, password: String) throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + "/api/session/" + session + "/prompt")))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "text":
        "Use somente a ferramenta shell, em primeiro plano, com command=\"sleep 40\". Não use outras ferramentas. Depois responda apenas: ok"
    ])
    let done = expectation(description: "prompt admitted")
    var status = 0
    URLSession.shared.dataTask(with: request) { _, response, _ in
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 30)
    XCTAssertTrue((200..<300).contains(status), "Prompt failed with HTTP \(status)")
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
