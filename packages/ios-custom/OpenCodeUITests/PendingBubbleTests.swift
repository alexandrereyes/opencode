import XCTest

/// Undelivered steers admitted with `resume: false` into owned imports. The waiting session's
/// imported idle marker is later than each admission, so its steers are stranded until delivered.
@MainActor final class PendingBubbleTests: XCTestCase {
  private struct InboxEnvelope: Decodable {
    struct Item: Decodable { let id: String; let delivery: String }
    let data: [Item]
  }
  private struct MessagesEnvelope: Decodable {
    struct Message: Decodable { let id: String; let type: String }
    let data: [Message]
  }
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
  /// Admits without waking execution, so the item stays pending until the test delivers it.
  private func admit(_ session: String, _ text: String, files: [[String: String]] = []) async throws -> String {
    let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var body: [String: Any] = ["id": id, "text": text, "delivery": "steer", "resume": false,
      "metadata": ["displayText": text, "comments": [] as [Any]]]
    if !files.isEmpty { body["files"] = files }
    _ = try await request("/api/session/\(session)/prompt", method: "POST", body: body)
    return id
  }
  private func inbox(_ session: String) async throws -> [InboxEnvelope.Item] {
    try JSONDecoder().decode(InboxEnvelope.self, from: await request("/api/session/\(session)/inbox")).data
  }
  private func launch(_ session: String, promptFixture: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenSession", session]
    app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
    if let promptFixture { app.launchEnvironment["OPENCODE_TEST_PROMPT_FIXTURE"] = promptFixture }
    app.launch()
    let transcript = app.collectionViews["conversation-transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 25))
    wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
    return app
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: Double = 25) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout), .completed)
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

  func testStrandedSteerIsPendingAndCanMoveToQueueOrBeDeleted() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PENDING_WAIT"])
    let queued = try await admit(session, "Pendente para mover · \(theme)",
      files: [["uri": "data:text/plain;base64,UGVuZGVudGU=", "name": "nota-pendente.txt"]])
    let deleted = try await admit(session, "Pendente para excluir · \(theme)")
    let app = launch(session)
    let bubble = element(app, "pending-user-" + queued)
    XCTAssertTrue(bubble.waitForExistence(timeout: 20))
    XCTAssertEqual(bubble.value as? String, "Pendente")
    XCTAssertTrue(element(app, "user-pending-" + queued).exists)
    XCTAssertTrue(app.staticTexts["nota-pendente.txt"].exists)
    XCTAssertFalse(element(app, "user-revert-" + queued).exists, "Pending actions replace Redefinir")
    XCTAssertTrue(app.buttons["user-pending-queue-" + queued].exists)
    XCTAssertTrue(app.buttons["user-pending-delete-" + deleted].exists)
    shot(app, "pending-stranded")

    // Long press offers the same actions in the native menu, without Redefinir.
    let reverts = app.buttons.matching(NSPredicate(format: "label == 'Redefinir para este ponto'")).count
    element(app, "user-prompt-" + deleted).press(forDuration: 1)
    XCTAssertTrue(app.buttons["Mover para a fila"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Excluir"].exists)
    XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Redefinir para este ponto'")).count, reverts)
    shot(app, "pending-menu")
    app.buttons["Excluir"].tap()
    wait(NSPredicate(format: "exists == false"), on: element(app, "pending-user-" + deleted))
    let afterDelete = try await inbox(session)
    XCTAssertFalse(afterDelete.contains { $0.id == deleted }, "Excluir cancels the inbox item on the server")

    app.buttons["user-pending-queue-" + queued].tap()
    wait(NSPredicate(format: "exists == false"), on: element(app, "pending-user-" + queued))
    XCTAssertTrue(element(app, "tray-queued-" + queued).waitForExistence(timeout: 10), "The moved steer waits in the queue tray")
    XCTAssertTrue(app.staticTexts["Na fila: Pendente para mover · \(theme)"].exists)
    XCTAssertTrue(app.buttons["Enviar agora"].exists)
    let afterMove = try await inbox(session)
    XCTAssertEqual(afterMove.first { $0.id == queued }?.delivery, "queue")
    shot(app, "pending-moved-to-queue")
    _ = try await request("/api/session/\(session)/inbox/\(queued)", method: "DELETE")
  }

  func testStartingSteerUsesPendingStyleWithPendingActions() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PENDING_START"])
    let starting = try await admit(session, "Pendente iniciando · \(theme)")
    let app = launch(session)
    let bubble = element(app, "pending-user-" + starting)
    XCTAssertTrue(bubble.waitForExistence(timeout: 20))
    // Unlike the web, a starting steer already uses the pending style and label.
    XCTAssertEqual(bubble.value as? String, "Pendente")
    XCTAssertTrue(element(app, "user-pending-" + starting).exists)
    XCTAssertTrue(app.buttons["user-pending-queue-" + starting].exists)
    XCTAssertTrue(app.buttons["user-pending-delete-" + starting].exists)
    shot(app, "pending-starting")
    app.buttons["user-pending-delete-" + starting].tap()
    wait(NSPredicate(format: "exists == false"), on: bubble)
    let remaining = try await inbox(session)
    XCTAssertFalse(remaining.contains { $0.id == starting })
  }

  /// Types and taps send, then returns the seconds until the user bubble appears. The sandbox
  /// fixture holds the prompt admission for `delay` milliseconds before answering.
  private func sendMeasured(_ app: XCUIApplication, _ text: String) -> (bubble: XCUIElement, seconds: Double) {
    let composer = app.textViews["conversation-composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 20))
    composer.tap()
    // A failed send in an earlier run keeps its persisted draft; start from an empty composer.
    let leftover = (composer.value as? String ?? "").count
    if leftover > 0 {
      composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
      composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: leftover))
    }
    composer.typeText(text)
    let send = app.buttons["Enviar mensagem"]
    wait(NSPredicate(format: "enabled == true"), on: send)
    let bubble = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    let start = Date()
    send.tap()
    XCTAssertTrue(bubble.waitForExistence(timeout: 30))
    let seconds = Date().timeIntervalSince(start)
    let measurement = XCTAttachment(string: String(format: "%.3f", seconds))
    measurement.name = "bubble-latency-" + theme
    measurement.lifetime = .keepAlways
    add(measurement)
    return (bubble, seconds)
  }

  func testOptimisticBubbleAppearsBeforeAdmissionAndReconciles() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PENDING_OPTIMISTIC"])
    let delay = environment["OPENCODE_TEST_PROMPT_DELAY"] ?? "5000"
    let app = launch(session, promptFixture: session + ":" + delay + ":admit")
    let text = "Envio otimista · \(theme)"
    let sent = sendMeasured(app, text)
    XCTAssertLessThan(sent.seconds, 4.5, "The bubble appears before the 5-second admission answers")
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String ?? "", "")
    // The optimistic row is pending-styled from the tap, before the server knows it.
    XCTAssertTrue(app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'pending-user-' AND value == 'Pendente'")).firstMatch.exists)
    XCTAssertTrue(app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'user-pending-'")).firstMatch.exists)
    shot(app, "optimistic-before-admission")
    var admitted: String?
    for _ in 0..<60 where admitted == nil {
      let data = try await request("/api/session/\(session)/inbox")
      let items = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      admitted = (items?["data"] as? [[String: Any]])?.first {
        (($0["payload"] as? [String: Any])?["text"] as? String) == text
      }?["id"] as? String
      if admitted == nil { try await Task.sleep(for: .milliseconds(250)) }
    }
    let id = try XCTUnwrap(admitted)
    XCTAssertTrue(element(app, "pending-user-" + id).waitForExistence(timeout: 15), "The optimistic bubble keeps the admitted ID")
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count, 1,
      "Reconciliation never duplicates the bubble")
    XCTAssertTrue(app.buttons["user-pending-delete-" + id].exists)
    shot(app, "optimistic-admitted")
    app.buttons["user-pending-delete-" + id].tap()
    wait(NSPredicate(format: "exists == false"), on: element(app, "pending-user-" + id))
  }

  func testFailedOptimisticSendRetractsTheBubbleAndRestoresTheDraft() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PENDING_OPTIMISTIC"])
    let app = launch(session, promptFixture: session + ":5000:fail")
    let text = "Envio que falha · \(theme)"
    let sent = sendMeasured(app, text)
    XCTAssertLessThan(sent.seconds, 4.5, "The bubble appears before the 5-second rejection")
    shot(app, "failure-before-response")
    XCTAssertTrue(app.staticTexts["send-error"].waitForExistence(timeout: 15))
    wait(NSPredicate(format: "exists == false"), on: sent.bubble)
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, text, "The draft returns to the composer")
    shot(app, "failure-restored")
    let pending = try await request("/api/session/\(session)/inbox")
    XCTAssertFalse(String(decoding: pending, as: UTF8.self).contains(text))
    let composer = app.textViews["conversation-composer"]
    composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
  }

  /// New sessions keep waiting for creation: no optimistic bubble, no duplicate after a retry.
  func testNewSessionCreationFailureKeepsTheDraftWithoutAnOrphanBubble() async throws {
    let project = try XCTUnwrap(environment["OPENCODE_TEST_PENDING_PROJECT"])
    let text = "Nova sessão com falha · \(theme) · \(UUID().uuidString.prefix(6))"
    func open(_ fixture: String) -> XCUIApplication {
      let app = XCUIApplication()
      app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = environment["OPENCODE_TEST_PASSWORD"]
      app.launchEnvironment["OPENCODE_TEST_PROMPT_FIXTURE"] = fixture
      app.launch()
      XCTAssertTrue(app.tabBars.buttons["Sessões"].waitForExistence(timeout: 20))
      app.tabBars.buttons["Sessões"].tap()
      if app.buttons["Fechar alerta"].exists { app.buttons["Fechar alerta"].tap() }
      app.buttons["Nova sessão"].tap()
      XCTAssertTrue(app.buttons["new-project"].waitForExistence(timeout: 20))
      wait(NSPredicate(format: "enabled == true"), on: app.buttons["new-project"], timeout: 30)
      XCTAssertTrue(app.buttons["model-picker"].waitForExistence(timeout: 20))
      return app
    }
    var app = open("create:2000:fail")
    app.buttons["new-project"].tap()
    XCTAssertTrue(app.buttons["new-project-" + project].waitForExistence(timeout: 10))
    app.buttons["new-project-" + project].tap()
    wait(NSPredicate(format: "label CONTAINS %@", project), on: app.buttons["new-project"])
    let input = app.textViews["conversation-composer"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    let leftover = (input.value as? String ?? "").count
    if leftover > 0 {
      input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
      input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: leftover))
    }
    input.typeText(text)
    app.buttons["Enviar mensagem"].tap()
    XCTAssertFalse(app.collectionViews["conversation-transcript"].exists)
    XCTAssertFalse(app.staticTexts[text].exists, "No bubble before the session exists")
    shot(app, "new-session-creating")
    XCTAssertTrue(app.descendants(matching: .any)["action-toast"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["new-project"].exists)
    XCTAssertFalse(app.collectionViews["conversation-transcript"].exists)
    XCTAssertEqual(input.value as? String, text, "The failed creation keeps the draft")
    shot(app, "new-session-creation-failed")
    app.terminate()

    // The persisted draft survives a relaunch; the retry admits one prompt without waking a model.
    app = open("*:0:admit")
    XCTAssertEqual(app.textViews["conversation-composer"].value as? String, text)
    app.buttons["Enviar mensagem"].tap()
    XCTAssertTrue(app.collectionViews["conversation-transcript"].waitForExistence(timeout: 60))
    XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 30))
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count, 1)
    shot(app, "new-session-retried")
  }

  func testStrandedSteerReturnsToTheSentStyleAfterDelivery() async throws {
    let session = try XCTUnwrap(environment["OPENCODE_TEST_PENDING_DELIVER"])
    let stranded = try await admit(session, "Responda apenas OK. · \(theme)")
    let app = launch(session)
    let bubble = element(app, "pending-user-" + stranded)
    XCTAssertTrue(bubble.waitForExistence(timeout: 20))
    XCTAssertEqual(bubble.value as? String, "Pendente")
    shot(app, "pending-before-delivery")
    // Resuming the idle session delivers pending steers as ordinary user messages (one tiny real model call).
    _ = try await request("/api/session/\(session)/interrupt?resume=true", method: "POST")
    wait(NSPredicate(format: "exists == false"), on: bubble, timeout: 90)
    XCTAssertTrue(element(app, "user-revert-" + stranded).waitForExistence(timeout: 20), "The delivered bubble offers Redefinir again")
    XCTAssertFalse(element(app, "user-pending-" + stranded).exists)
    XCTAssertFalse(element(app, "user-pending-queue-" + stranded).exists)
    let messages = try JSONDecoder().decode(MessagesEnvelope.self, from: await request("/api/session/\(session)/message?limit=100")).data
    XCTAssertTrue(messages.contains { $0.id == stranded && $0.type == "user" })
    let remaining = try await inbox(session)
    XCTAssertFalse(remaining.contains { $0.id == stranded })
    shot(app, "pending-after-delivery")
  }
}
