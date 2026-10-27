import XCTest

/// Prepared by `script/test-session-chips.py`: nothing runs, every root session is read except one in each of two
/// repositories. `OPENCODE_TEST_CHIP_MANUAL` is the saved repository order, `OPENCODE_TEST_CHIP_UNREAD` the two unread
/// repositories (in manual order), `OPENCODE_TEST_CHIP_SESSION` the title to read in the second one, and
/// `OPENCODE_TEST_CHIP_RUN_PROJECT`/`OPENCODE_TEST_CHIP_RUN_SESSION` a read repository and the session ID the test
/// runs briefly with one Luna 6 / low prompt. `OPENCODE_TEST_CHIP_ICONS` (`name=RRGGBB,…`) lists repositories with an
/// icon and a color it clearly shows (the others have none); `OPENCODE_TEST_CHIP_ICON_LIVE` (`name,projectID`) is a
/// read one whose icon the test removes and restores through the API.
@MainActor final class SessionChipsTests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }

  func testRunningThenUnreadThenManualOrderAndClearingAfterReading() throws {
    continueAfterFailure = false
    let manual = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_MANUAL"]).split(separator: ",").map(String.init)
    let unread = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_UNREAD"]).split(separator: ",").map(String.init)
    let title = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_SESSION"])
    let run = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_RUN_PROJECT"])
    let runSession = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_RUN_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = password
    app.launch()
    defer { app.terminate() }
    try app.requireSandbox()
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 20))
    // The runner resets Chats to the start of the saved order.
    var combined = ["Chats"] + manual

    // Unread repositories first, then the rest, each in the saved order (Chats included).
    XCTAssertTrue(settled(app, order: expected(combined, unread: Set(unread))))
    for name in manual {
      XCTAssertEqual(chip(name, app).label, unread.contains(name) ? name + ", com não lidas" : name)
    }
    // "Todas" is a compact, icon-only chip that still reads and reports its selection.
    let all = app.buttons["filter-all"]
    XCTAssertEqual(all.label, "Todas")
    XCTAssertTrue(all.isSelected)
    XCTAssertTrue(all.frame.width >= 44 && all.frame.width <= 56, "Todas width \(all.frame.width)")
    XCTAssertEqual(all.frame.height, chip(manual[0], app).frame.height, accuracy: 0.5)
    shot("chips-unread")
    try checkIcons(manual, unread: Set(unread), app: app, password: password)

    // A running repository rises right after "Todas", above the unread ones.
    try prompt(runSession, password: password)
    XCTAssertTrue(settled(app, order: expected(combined, running: [run], unread: Set(unread)), timeout: 60))
    shot("chips-running")

    // Once it finishes it is unread too, so it returns among the unread chips at its saved position.
    let finished = Set(unread + [run])
    XCTAssertTrue(settled(app, order: expected(combined, unread: finished), timeout: 180))
    shot("chips-finished")

    // The finished run's completion banner can cover the chips; close it first.
    if app.buttons["Fechar alerta"].waitForExistence(timeout: 3) { app.buttons["Fechar alerta"].tap() }
    chip(unread[1], app).tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    let header = app.staticTexts["conversation-header-title"]
    XCTAssertTrue(header.waitForExistence(timeout: 30))
    XCTAssertEqual(header.label, title)
    // The viewed watermark is acknowledged once the transcript tail has been shown.
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 30))
    Thread.sleep(forTimeInterval: 2)
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["conversation-header-title"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 10))

    // Reading clears the dot; the chip returns to its saved place among the read chips.
    let stillUnread = finished.subtracting([unread[1]])
    XCTAssertTrue(settled(app, order: expected(combined, unread: stillUnread)))
    XCTAssertEqual(chip(unread[1], app).label, unread[1])
    // The active filter stays visible after moving.
    let selected = chip(unread[1], app)
    let visible = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in selected.frame.minX >= 0 && selected.frame.maxX <= app.frame.maxX + 1 },
      object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "Selected chip off screen")
    shot("chips-after-reading")
    app.buttons["filter-all"].tap()

    // Chats moves in the saved order like a repository, and the position persists on the server.
    move("Chats", "Mover para depois", app)
    combined = [manual[0], "Chats"] + manual.dropFirst()
    XCTAssertTrue(settled(app, order: expected(combined, unread: stillUnread)))
    shot("chips-chats-moved")
    app.terminate()
    app.launch()
    try app.requireSandbox()
    XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Sessões"].tap()
    XCTAssertTrue(app.buttons["filter-chats"].waitForExistence(timeout: 20))
    XCTAssertTrue(settled(app, order: expected(combined, unread: stillUnread)))
    shot("chips-chats-reopened")
    // A repository passing Chats moves Chats back to the start.
    move(manual[0], "Mover para depois", app)
    combined = ["Chats"] + manual
    XCTAssertTrue(settled(app, order: expected(combined, unread: stillUnread)))
  }

  /// "Todas", then running (running + unread first), then unread, then the rest, each in the saved order.
  private func expected(_ combined: [String], running: Set<String> = [], unread: Set<String>) -> [String] {
    ["Todas"] + combined.filter { running.contains($0) && unread.contains($0) }
      + combined.filter { running.contains($0) && !unread.contains($0) }
      + combined.filter { !running.contains($0) && unread.contains($0) }
      + combined.filter { !running.contains($0) && !unread.contains($0) }
  }
  private func move(_ name: String, _ direction: String, _ app: XCUIApplication) {
    let target = chip(name, app)
    for _ in 0..<6 where !target.isHittable { app.scrollViews.firstMatch.swipeLeft(velocity: .slow) }
    target.press(forDuration: 1.0)
    XCTAssertTrue(app.buttons[direction].waitForExistence(timeout: 5))
    app.buttons[direction].tap()
    let confirm = app.buttons["Confirmar nova posição"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
  }

  /// Each repository's own icon (or none) beside its name, and a live change through the API without reopening.
  private func checkIcons(_ manual: [String], unread: Set<String>, app: XCUIApplication, password: String) throws {
    let icons = Dictionary(
      uniqueKeysWithValues: (environment["OPENCODE_TEST_CHIP_ICONS"] ?? "").split(separator: ",").map {
        let pair = $0.split(separator: "=")
        return (String(pair[0]), String(pair[1]))
      })
    guard !icons.isEmpty else { return }
    for name in manual {
      for (owner, color) in icons {
        let count = pixels(chip(name, app), near: color, app)
        if name == owner { XCTAssertGreaterThan(count, 20, "\(name) icon") }
        // An unread chip's orange dot may match an icon color.
        else if !icons.keys.contains(name) && !unread.contains(name) {
          XCTAssertEqual(count, 0, "\(name) shows \(owner)'s icon")
        }
      }
    }
    let live = try XCTUnwrap(environment["OPENCODE_TEST_CHIP_ICON_LIVE"]).split(separator: ",").map(String.init)
    let color = try XCTUnwrap(icons[live[0]])
    let target = chip(live[0], app)
    shot("chips-icons")
    let projects = try XCTUnwrap(try request("GET", "/api/project", password: password) as? [[String: Any]])
    let icon = try XCTUnwrap(projects.first { $0["id"] as? String == live[1] }?["icon"] as? [String: Any])
    let source = try XCTUnwrap(icon["override"] as? String)
    let width = target.frame.width
    _ = try request("PATCH", "/api/project/" + live[1], ["icon": ["override": ""]], password: password)
    XCTAssertTrue(wait({ self.pixels(target, near: color, app) == 0 && target.frame.width < width - 15 }))
    _ = try request("PATCH", "/api/project/" + live[1], ["icon": ["override": source]], password: password)
    XCTAssertTrue(wait({ self.pixels(target, near: color, app) > 20 && abs(target.frame.width - width) < 1 }))
  }
  /// On-screen pixels of an element close to `hex`, the color an icon clearly shows.
  private func pixels(_ element: XCUIElement, near hex: String, _ app: XCUIApplication) -> Int {
    let strip = app.scrollViews.firstMatch
    for _ in 0..<6 where element.frame.maxX > app.frame.maxX { strip.swipeLeft(velocity: .slow) }
    for _ in 0..<6 where element.frame.minX < 0 { strip.swipeRight(velocity: .slow) }
    guard let image = element.screenshot().image.cgImage, let value = UInt32(hex, radix: 16) else { return 0 }
    let target = [Int(value >> 16 & 255), Int(value >> 8 & 255), Int(value & 255)]
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard
      let context = CGContext(
        data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return stride(from: 0, to: buffer.count, by: 4).filter { index in
      (0..<3).allSatisfy { abs(Int(buffer[index + $0]) - target[$0]) <= 24 }
    }.count
  }
  private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  /// A short real execution: one foreground shell sleep, so the chip stays running for a few seconds.
  private func prompt(_ session: String, password: String) throws {
    _ = try request(
      "POST", "/api/session/" + session + "/prompt",
      [
        "text":
          "Use somente a ferramenta shell, em primeiro plano, com command=\"sleep 20\". Não use outras ferramentas. Depois responda apenas: ok"
      ], password: password)
  }
  private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil, password: String) throws
    -> Any?
  {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + path)))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let done = expectation(description: method + " " + path)
    var status = 0
    var data: Data?
    URLSession.shared.dataTask(with: request) { value, response, _ in
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      data = value
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 30)
    XCTAssertTrue((200..<300).contains(status), "\(method) \(path) failed with HTTP \(status)")
    return data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
  }
  private func chip(_ name: String, _ app: XCUIApplication) -> XCUIElement {
    switch name {
    case "Chats": app.buttons["filter-chats"]
    case "Todas": app.buttons["filter-all"]
    default: app.buttons["filter-project-" + name]
    }
  }
  /// Chip frames in the horizontal strip, compared left to right once the reorder animation settles.
  private func settled(_ app: XCUIApplication, order: [String], timeout: TimeInterval = 30) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let elements = order.map { self.chip($0, app) }
        guard elements.allSatisfy(\.exists) else { return false }
        let positions = elements.map(\.frame.minX)
        return zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
      }, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
