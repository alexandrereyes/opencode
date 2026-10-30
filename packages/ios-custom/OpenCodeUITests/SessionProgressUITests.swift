import XCTest

/// Progresso (rev. 2026-10-30) against an isolated sandbox whose fake repository turns `experimental.todo` on. The
/// owned import's transcript already ends with a completed `todowrite` (3 completed, 1 in progress, 2 pending, 1
/// cancelled); one tiny real prompt (Luna 6/low, `sleep 45`) makes the session itself work. While it runs, the
/// Sessões row, the pill and its sheet show 3/7; when the run ends, they go away. `script/test-progress.py`.
@MainActor final class SessionProgressUITests: XCTestCase {
  private static let current = "Atualizar a Live Activity e o relógio"
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var theme: String { environment["OPENCODE_TEST_THEME"] ?? "openchamber-dark" }
  override func setUp() { continueAfterFailure = false }

  private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
    var request = URLRequest(url: try XCTUnwrap(URL(string: TestSandbox.url + path)))
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode), path)
    return data
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: Double = 25) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout), .completed,
      "\(predicate) · \(element.debugDescription.prefix(300))")
  }
  private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name + "-" + theme
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id]
  }

  func testProgressShowsWhileTheSessionWorksAndLeavesWhenItEnds() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PROGRESS_SESSION"])
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
    app.launch()
    try app.requireSandbox()
    let row = element(app, "session-row-" + session)
    XCTAssertTrue(row.waitForExistence(timeout: 30))
    XCTAssertFalse(row.label.contains("3/7"), "An idle session shows no Progresso: \(row.label)")

    // One tiny real run that never touches the list.
    _ = try await request("/api/session/\(session)/prompt", method: "POST", body: [
      "id": "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
      "text": "Use a ferramenta shell para rodar exatamente: sleep 45. Não use todowrite. Depois responda só: pronto.",
      "delivery": "steer",
    ])
    wait(NSPredicate(format: "label CONTAINS %@", "trabalhando · 3/7 \(Self.current)"), on: row, timeout: 60)
    shot(app, "progress-row")

    row.tap()
    let pill = app.buttons["conversation-progress"]
    XCTAssertTrue(pill.waitForExistence(timeout: 30))
    XCTAssertEqual(pill.label, "Progresso: 3 de 7. Agora: \(Self.current)")
    shot(app, "progress-pill")

    pill.tap()
    let first = element(app, "conversation-progress-item-0")
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertEqual(first.label, "Concluída: Ler o rastreador da Live Activity")
    XCTAssertEqual(element(app, "conversation-progress-item-3").label, "Em andamento: \(Self.current)")
    XCTAssertEqual(element(app, "conversation-progress-item-4").label, "Pendente: Rodar os testes do OpenCodeKit")
    XCTAssertEqual(element(app, "conversation-progress-item-6").label, "Cancelada: Migrar as fixtures antigas")
    XCTAssertFalse(element(app, "conversation-progress-item-7").exists)
    shot(app, "progress-sheet")
    app.buttons["Fechar"].firstMatch.tap()
    wait(NSPredicate(format: "exists == false"), on: first, timeout: 10)

    // The run ends on its own: the pill leaves, and so does the row's Progresso.
    wait(NSPredicate(format: "exists == false"), on: pill, timeout: 180)
    shot(app, "progress-ended")
    app.buttons["Voltar"].firstMatch.tap()
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    wait(NSPredicate(format: "NOT (label CONTAINS '3/7')"), on: row, timeout: 30)
    shot(app, "progress-row-ended")
  }
}
