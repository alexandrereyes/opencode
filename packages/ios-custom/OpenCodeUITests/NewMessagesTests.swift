import XCTest

@MainActor final class NewMessagesTests: XCTestCase {
  private struct SessionEnvelope: Decodable {
    struct Info: Decodable {
      struct Time: Decodable { let idle: Double?; let viewed: Double? }
      let time: Time
    }
    let data: Info
  }
  private struct ActiveEnvelope: Decodable {
    struct State: Decodable { let type: String }
    let data: [String: State]
  }
  private struct Prompt: Encodable {
    struct Model: Encodable {
      let providerID = "llm-proxy"
      let id = "gpt-6-luna"
      let variant = "low"
    }
    let text: String
    let agent = "build"
    let model = Model()
  }
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  override func setUp() { continueAfterFailure = false }

  private func request(_ path: String, prompt: String? = nil) async throws -> Data {
    var request = URLRequest(url: URL(string: TestSandbox.url + path)!)
    let password = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
    request.setValue("Basic " + Data(("opencode:" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    if let prompt {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(Prompt(text: prompt))
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
    return data
  }
  private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: Double = 25) {
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout), .completed)
  }
  private func screenshot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func waitForIdle(_ id: String) async throws {
    for _ in 0..<240 {
      let active = try JSONDecoder().decode(ActiveEnvelope.self, from: await request("/api/session/active"))
      if active.data[id] == nil { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    XCTFail("A execução própria deve terminar antes de sair do teste")
  }
  private func waitForViewed(_ id: String) async throws {
    for _ in 0..<80 {
      let session = try JSONDecoder().decode(SessionEnvelope.self, from: await request("/api/session/" + id)).data
      if session.time.idle != nil && session.time.idle == session.time.viewed { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("A rota deve reconhecer seu idle sem depender da posição de leitura")
  }

  func testStreamingSubmitChildAndPaginationInBothThemes() async throws {
    // The long live history can be assigned one theme per runner invocation.
    let themes = [("DARK", "openchamber-dark"), ("LIGHT", "openchamber-light")].filter {
      environment["OPENCODE_TEST_THEME"] == nil || environment["OPENCODE_TEST_THEME"] == $0.1
    }
    XCTAssertFalse(themes.isEmpty)
    for (key, theme) in themes {
      let root = try XCTUnwrap(environment["OPENCODE_NOVAS_ROOT_" + key])
      let childID = try XCTUnwrap(environment["OPENCODE_NOVAS_CHILD_" + key])
      let app = XCUIApplication()
      app.launchArguments = ["-OpenCodeServerURL", TestSandbox.url, "-OpenCodeTheme", theme, "-OpenCodeOpenSession", root]
      app.launchEnvironment["OPENCODE_SERVER_PASSWORD"] = try XCTUnwrap(environment["OPENCODE_TEST_PASSWORD"])
      app.launch()
      let transcript = app.collectionViews["conversation-transcript"]
      XCTAssertTrue(transcript.waitForExistence(timeout: 25))
      wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
      try await waitForViewed(root)
      let unopened = try JSONDecoder().decode(SessionEnvelope.self, from: await request("/api/session/" + childID)).data
      XCTAssertNotEqual(unopened.time.viewed, unopened.time.idle)
      let latest = app.buttons["Ir para a mais recente"]
      XCTAssertFalse(latest.exists)
      XCTAssertFalse(app.buttons["Ir às novas mensagens"].exists)
      XCTAssertFalse(app.staticTexts["Novas mensagens"].exists)
      screenshot(app, "app-tail-" + theme)

      let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
      start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 140)),
        withVelocity: .slow, thenHoldForDuration: 0.3)
      XCTAssertFalse(latest.exists, "Uma pequena distância do fim não oferece o salto")
      screenshot(app, "app-near-" + theme)
      for _ in 0..<3 { transcript.swipeDown(velocity: .slow) }
      XCTAssertTrue(latest.waitForExistence(timeout: 10))
      screenshot(app, "app-history-live-" + theme)
      let response = try XCTUnwrap(app.textViews.allElementsBoundByAccessibilityElement.filter {
        $0.identifier.hasPrefix("response-") && $0.frame.maxY > transcript.frame.minY + 140 && $0.frame.minY < transcript.frame.maxY
      }.min { $0.frame.minY < $1.frame.minY })
      let identifier = response.identifier
      let passage = try XCTUnwrap(response.value as? String)
      let anchored = app.textViews.matching(identifier: identifier)
        .matching(NSPredicate(format: "value == %@", passage)).firstMatch
      let y = response.frame.minY
      let count = try XCTUnwrap(transcript.value as? String)
      _ = try await request("/api/session/" + root + "/prompt", prompt: "Verificação isolada: execute quatro chamadas separadas à ferramenta shell, apenas pwd, com breve progresso entre chamadas. Ao final escreva um checklist sintético numerado de 24 linhas. Não altere arquivos, não use rede e não crie subagentes.")
      wait(NSPredicate(format: "value != %@", count), on: transcript)
      XCTAssertTrue(latest.exists)
      XCTAssertTrue(anchored.exists)
      XCTAssertEqual(anchored.frame.minY, y, accuracy: 3)
      XCTAssertFalse(app.staticTexts["Novas mensagens"].exists)
      screenshot(app, "app-streaming-away-" + theme)
      try await waitForIdle(root)
      try await waitForViewed(root)
      XCTAssertEqual(anchored.frame.minY, y, accuracy: 3)

      let editor = app.textViews["conversation-composer"]
      editor.tap()
      editor.typeText("Responda apenas OK, sem ferramentas.")
      app.buttons["Enviar mensagem"].tap()
      wait(NSPredicate(format: "exists == false"), on: latest)
      try await waitForIdle(root)
      screenshot(app, "app-submit-" + theme)
      transcript.tap()
      let child = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Abrir filho de teste'")).firstMatch
      // The streamed checklist can wrap across several screens at the larger type scale.
      for _ in 0..<40 {
        let visible = app.transcriptViewport(transcript)
        if child.exists && child.isHittable && visible.contains(child.frame) { break }
        if !child.exists, let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-group-'"))
          .allElementsBoundByIndex.first(where: { visible.contains($0.frame) && $0.isHittable && $0.value as? String == "Recolhido" }) {
          group.tap()
          continue
        }
        if child.exists {
          let frame = child.frame
          app.dragTranscript(transcript, viewport: visible,
            delta: frame.minY < visible.minY ? visible.minY - frame.minY : visible.maxY - frame.maxY)
          continue
        }
        app.dragTranscript(transcript, viewport: visible, delta: 120)
      }
      XCTAssertTrue(child.exists && child.isHittable)
      XCTAssertTrue(app.transcriptViewport(transcript).contains(child.frame))
      child.tap()
      XCTAssertTrue(app.buttons["subagent-badge"].waitForExistence(timeout: 20))
      wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
      try await waitForViewed(childID)
      screenshot(app, "app-child-" + theme)
      // Opened from the parent's transcript: Back returns to it.
      app.buttons["conversation-back"].tap()
      wait(NSPredicate(format: "value != 'Restaurando leitura'"), on: transcript)
      screenshot(app, "app-return-child-" + theme)
      XCTAssertFalse(app.buttons["Ir às novas mensagens"].exists)
      let oldest = app.textViews.matching(NSPredicate(format: "value == 'Etapa 1'")).firstMatch
      // Center-origin swipes can scroll the pinned prompt instead of paging the transcript.
      for _ in 0..<48 {
        if oldest.exists && oldest.isHittable { break }
        let visible = app.transcriptViewport(transcript)
        let start = transcript.coordinate(withNormalizedOffset: .zero)
          .withOffset(CGVector(dx: 32, dy: visible.minY + visible.height * 0.1 - transcript.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: visible.height * 0.8)),
          withVelocity: .fast, thenHoldForDuration: 0)
      }
      XCTAssertTrue(oldest.exists && oldest.isHittable, "A paginação deve chegar à primeira resposta")
      screenshot(app, "app-pagination-" + theme)
      XCTAssertTrue(latest.exists)
      latest.tap()
      wait(NSPredicate(format: "exists == false"), on: latest)
      screenshot(app, "app-tapped-live-" + theme)
      app.terminate()
    }
  }
}
