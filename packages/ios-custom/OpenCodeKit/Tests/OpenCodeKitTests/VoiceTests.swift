import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceTests {
  @Test func instructionsComeFromTheServerRPCAndRejectEmptyText() async throws {
    for text in ["Prompt editado no servidor", "  \n"] {
      let client = OpenCodeClient(configuration: .init(url: URL(string: "http://127.0.0.1:4177")!), transport: { request in
        #expect(request.url?.path == "/api/rpc/custom.voice/instructions")
        return (try JSONEncoder().encode(["output": ["instructions": text]]),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      })
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await #expect(throws: ClientError.self) { try await client.voiceInstructions() }
      } else {
        #expect(try await client.voiceInstructions() == text)
      }
    }
  }
  @Test func signalingDoesNotCarryCredentials() throws {
    let signal = VoiceSignaling()
    let request = try signal.offerRequest(sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n", instructions: "Prompt do servidor")
    #expect(request.url?.host == "llm-proxy-svc")
    #expect(request.url?.path == "/backend-api/codex/realtime/calls")
    #expect(request.url?.query == "intent=quicksilver&architecture=avas")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "x-gpt-live-generation") == signal.generation.uuidString)
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    #expect(body.object?["session"]?.object?["model"]?.string == "gpt-live-1-codex")
    #expect(body.object?["session"]?.object?["instructions"]?.string == "Prompt do servidor")
    #expect(body.object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"]?.string == "rio")
    #expect(body.object?["session"]?.object?["delegation"]?.object?["type"]?.string == "client")
  }
  @Test func leaseIdentityAndTimeAreValidated() throws {
    let signal = VoiceSignaling()
    let data = Data("""
      {"sessionId":"\(signal.sessionID)","generation":"\(signal.generation)",
       "serverTime":"2026-10-23T12:00:00.123Z","leaseExpiresAt":"2026-10-23T12:01:00.123Z"}
      """.utf8)
    #expect(try signal.parseLease(data, status: 200).remaining == 60)
    #expect(throws: VoiceWireError.self) { try VoiceSignaling().parseLease(data, status: 200) }
    #expect(throws: VoiceWireError.self) { try signal.parseLease(data, status: 409) }
    #expect(try signal.leaseRequest(method: "PUT").httpMethod == "PUT")
    let release = try signal.leaseRequest(method: "DELETE")
    #expect(release.httpBody == nil)
    #expect(release.url?.query?.contains(signal.generation.uuidString) == true)
  }
  @Test func answerRequiresRealSDPAndCreatedStatus() throws {
    let url = VoiceSignaling.baseURL
    let response = try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
      headerFields: ["Location": "/v1/live/test"]))
    let data = Data("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n".utf8)
    #expect(try VoiceSignaling.parseAnswer(data, response: response).hasPrefix("v=0"))
    #expect(throws: VoiceWireError.self) { try VoiceSignaling.parseAnswer(Data("{}".utf8), response: response) }
    // GPT Live's ID of the call is the last segment of the Location, as on 02/11.
    #expect(VoiceSignaling.callID(response) == "test")
    for location in ["/v1/realtime/calls/rtc_u4_Efq67p3o", "/v1/realtime/calls/rtc_u4_Efq67p3o/", "/v1/realtime/calls/rtc_u4_Efq67p3o?x=1"] {
      let created = try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: ["Location": location]))
      #expect(VoiceSignaling.callID(created) == "rtc_u4_Efq67p3o")
    }
    #expect(VoiceSignaling.callID(try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil))) == nil)
  }
  @Test func delegationFixture() throws {
    let event = try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"ask-1","content":[{"type":"input_text","text":"Confira as sessões"}]}}"#.utf8))
    #expect(event == .delegation(id: "ask-1", text: "Confira as sessões"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.started"}"#.utf8)) == .ready())
    // As the route sent it on 02/11: the call's ID and when the session expires.
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.started","session":{"id":"rtc_u4_Efq67p3o","status":"active","expires_at":1793647619}}"#.utf8))
      == .ready(call: "rtc_u4_Efq67p3o", expiresAt: 1_793_647_619))
    #expect(throws: VoiceWireError.self) { try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client"}}"#.utf8)) }
    #expect(try VoiceProtocol.decode(Data(#"{"type":"novo.evento"}"#.utf8)) == .ignored)
    // With an ID but no readable request, the delegation is answered instead of dropped.
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"ask-2","content":[]}}"#.utf8))
      == .unreadableDelegation(id: "ask-2"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"ask-3"}}"#.utf8))
      == .unreadableDelegation(id: "ask-3"))
    // As the route sent it on 02/11: the text is the transcript of the user turn it names.
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"id":"item_E","type":"delegation","content":[{"type":"input_text","text":"Olha a minha tela, o que tem aí"}],"handoff_id":"handoff_1","target":"client","user_bidi_turn_id":"turn_E"},"offset_ms":15000}"#.utf8))
      == .delegation(id: "item_E", text: "Olha a minha tela, o que tem aí", turn: "turn_E"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"id":"item_F","type":"delegation","content":[],"target":"client","user_bidi_turn_id":"turn_F"}}"#.utf8))
      == .unreadableDelegation(id: "item_F", turn: "turn_F"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.closed"}"#.utf8)) == .closed())
  }
  /// `session.closed` as the route sent it on 02/11, and shapes it might send: the reason and the audio it counted are
  /// optional, and a field of another type is left out instead of losing the event.
  @Test func sessionClosedCarriesItsReasonAndUsage() throws {
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.closed","reason":"client_request","usage":{"audio_duration_ms":86800,"backend_model_usage":[]}}"#.utf8))
      == .closed(reason: "client_request", audioMs: 86_800))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.closed","reason":7,"usage":{"audio_duration_ms":1e300}}"#.utf8))
      == .closed())
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.closed","reason":"expired","usage":null}"#.utf8))
      == .closed(reason: "expired"))
    let close = VoiceProtocol.close()
    #expect(try JSONDecoder().decode(JSONValue.self, from: close.data)
      == .object(["type": .string("session.close"), "event_id": .string(close.id)]))
    #expect(close.type == "session.close" && close.target == nil)
  }
  /// Every command carries an `event_id` of the app's; GPT Live names it in `error.event_id`, while the event's own
  /// `event_id` is the service's (02/11).
  @Test func commandsCarryTheirOwnEventIDAndErrorsNameIt() throws {
    let commands = try VoiceProtocol.append(id: "item_1", text: String(repeating: "é", count: 300))
      + VoiceProtocol.contextAppend("Resultado.") + [VoiceProtocol.close()]
    #expect(commands.map(\.type) == ["delegation.context.append", "delegation.context.append", "session.context.append", "session.close"])
    #expect(commands.map(\.target) == [.delegation("item_1"), .delegation("item_1"), .session, nil])
    #expect(Set(commands.map(\.id)).count == commands.count)
    for command in commands {
      #expect(command.id.wholeMatch(of: /oc_[0-9a-f]{16}/) != nil)
      let object = try #require(JSONDecoder().decode(JSONValue.self, from: command.data).object)
      #expect(object["event_id"]?.string == command.id && object["type"]?.string == command.type)
    }
    #expect(try VoiceProtocol.decode(Data(#"{"type":"error","event_id":"event_Efq6Nz","error":{"type":"invalid_request_error","code":"invalid_request_error","message":"Unknown delegation item id: item_x","param":null,"event_id":"oc_0123456789abcdef"}}"#.utf8))
      == .failure(code: "invalid_request_error/invalid_request_error", detail: "Unknown delegation item id: item_x",
        command: "oc_0123456789abcdef"))
    // Without ours, `error.event_id` is null; the service's at the top level never stands in for it.
    for json in [#"{"type":"error","event_id":"event_Efq6Nz","error":{"type":"server_error","event_id":null}}"#,
      #"{"type":"error","event_id":"event_Efq6Nz","code":"server_error"}"#] {
      guard case .failure(_, _, let command) = try VoiceProtocol.decode(Data(json.utf8)) else { Issue.record(); continue }
      #expect(command == nil)
    }
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.context.appended","end_ms":12400,"start_ms":12200}"#.utf8)) == .appended(.session))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.context.appended","delegation_item_id":"item_E","end_ms":30800,"start_ms":30600}"#.utf8))
      == .appended(.delegation("item_E")))
    #expect(throws: VoiceWireError.self) { try VoiceProtocol.decode(Data(#"{"type":"delegation.context.appended"}"#.utf8)) }
  }
  /// Confirmations carry no ID: the session's answers its oldest append still waiting, a delegation's the oldest of its
  /// item; an append an error named never gets one, and a confirmation with nothing waiting matches nothing.
  @Test func commandLogMatchesConfirmationsByOrderAndItem() throws {
    var log = VoiceCommandLog()
    let first = try VoiceProtocol.append(id: "a", text: "Um."), quiet = try VoiceProtocol.append(id: "a", text: "Dois.", channel: .commentary)
    let other = try VoiceProtocol.append(id: "b", text: "Três."), context = try VoiceProtocol.contextAppend("Quatro.")
    for (command, purpose) in [(first[0], VoiceCommandLog.Purpose.narration), (other[0], .answer), (quiet[0], .status),
      (context[0], .context)] { log.record(command, purpose: purpose, at: 10) }
    #expect(log.confirmed(.delegation("a"))?.id == first[0].id)
    #expect(log.failed(quiet[0].id).map { [$0.type, $0.purpose.rawValue] } == ["delegation.context.append", "status"])
    #expect(log.confirmed(.delegation("a")) == nil, "the refused one gets no confirmation")
    #expect(log.confirmed(.delegation("b"))?.id == other[0].id)
    #expect(log.confirmed(.session).map { [$0.id, $0.purpose.rawValue] } == [context[0].id, "context"])
    #expect(log.confirmed(.session) == nil)
    #expect(log.failed("oc_0000000000000000") == nil && log.failed(nil) == nil)
    // Only the newest are kept.
    for _ in 0..<VoiceCommandLog.capacity { log.record(try VoiceProtocol.contextAppend("x")[0], purpose: .context, at: 12) }
    #expect(log.failed(first[0].id) == nil)
  }
  /// A close reason names moderation by OpenAI's `content` or any reason that mentions content or moderation; the
  /// reasons seen or documented for other ends do not.
  @Test func closeReasonsThatNameModeration() {
    for reason in ["content", "content_filter", "moderation", "Moderated"] { #expect(VoiceProtocol.closedByModeration(reason)) }
    for reason in [nil, "client_request", "close_requested", "expired", "remote_hangup", "connection_lost", "novo"] {
      #expect(!VoiceProtocol.closedByModeration(reason))
    }
  }
  /// Only an expired session ends GPT Live's session; every other error leaves it open.
  @Test func onlyAnExpiredSessionEndsTheCall() throws {
    func code(_ json: String) throws -> String? {
      guard case .failure(let code, _, _) = try VoiceProtocol.decode(Data(json.utf8)) else { return "not a failure" }
      return code
    }
    let expired = try code(#"{"type":"error","error":{"type":"invalid_request_error","code":"session_expired","message":"…"}}"#)
    #expect(VoiceProtocol.endsSession(expired))
    #expect(VoiceProtocol.endsSession("session_expired"))
    for json in [
      #"{"type":"error","error":{"type":"server_error","code":"internal"}}"#,
      #"{"type":"error","error":{"type":"invalid_request_error","code":"conversation_already_has_active_response"}}"#,
      #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_value"}}"#,
      #"{"type":"error","error":{"type":"rate_limit_error","code":"rate_limit_exceeded"}}"#,
      #"{"type":"error"}"#,
    ] { #expect(!VoiceProtocol.endsSession(try code(json))) }
  }
  /// Moderation is recognized only by the error's structured type/code, never by text.
  @Test func moderationIsTheStructuredContentFilterOnly() throws {
    func code(_ json: String) throws -> String? {
      guard case .failure(let code, _, _) = try VoiceProtocol.decode(Data(json.utf8)) else { return "not a failure" }
      return code
    }
    #expect(VoiceProtocol.isModeration(try code(#"{"type":"error","error":{"type":"content_filter","code":"content_filter","message":"The generation was stopped due to moderation."}}"#)))
    #expect(VoiceProtocol.isModeration(try code(#"{"type":"error","code":"content_filter"}"#)))
    for json in [
      #"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_value","message":"content_filter"}}"#,
      #"{"type":"error","error":{"type":"server_error","code":"internal"}}"#,
      #"{"type":"error","error":"content_filter"}"#,
      #"{"type":"error"}"#,
    ] { #expect(!VoiceProtocol.isModeration(try code(json))) }
  }
  @Test func callContextGoesInChunksWithoutADelegation() throws {
    let text = String(repeating: "Resultado: ação concluída. ", count: 40)
    let frames = try VoiceProtocol.contextAppend(text)
    #expect(frames.count > 1)
    let parts = try frames.map { frame -> String in
      let value = try #require(JSONDecoder().decode(JSONValue.self, from: frame.data).object)
      #expect(value["type"]?.string == "session.context.append")
      #expect(value["delegation_item_id"] == nil)
      return try #require(value["content"]?.array?.first?.object?["text"]?.string)
    }
    #expect(parts.allSatisfy { $0.utf8.count <= 500 } && parts.joined() == text)
    #expect(throws: VoiceWireError.self) { try VoiceProtocol.contextAppend("") }
  }
  @Test func narrationPutsBackAnUnheardText() {
    var narration = VoiceNarration()
    narration.offer("Resultado: pronto.")
    #expect(narration.take(now: 10, speaking: false, userUntil: 0, final: true) == "Resultado: pronto.")
    narration.offer("Resultado: pronto.")
    #expect(narration.waiting == nil, "the same text is not said twice")
    narration.retry("Resultado: pronto.")
    #expect(narration.waiting == "Resultado: pronto.", "unless it was not heard")
    narration.retry("Outro")
    #expect(narration.waiting == "Resultado: pronto.", "a text already waiting is kept")
  }
  @Test func unicodeChunksRemainWithinWireBudget() throws {
    let text = String(repeating: "Olá 👩🏽‍💻, verificação. ", count: 100)
    let frames = try VoiceProtocol.append(id: "ask-1", text: text)
    let chunks = try frames.map { frame -> String in
      let value = try JSONDecoder().decode(JSONValue.self, from: frame.data)
      #expect(value.object?["delegation_item_id"]?.string == "ask-1")
      return try #require(value.object?["content"]?.array?.first?.object?["text"]?.string)
    }
    #expect(chunks.allSatisfy { $0.utf8.count <= 500 })
    #expect(chunks.joined() == text)
  }
  @Test func stateMachineAndBargeIn() {
    var state = VoiceState()
    state.apply(.connected)
    #expect(state.phase == .idle)
    state.apply(.start); state.apply(.connected); state.apply(.speech)
    #expect(state.phase == .speaking)
    state.apply(.bargeIn)
    #expect(state.phase == .listening)
    state.masterWorking = true
    #expect(state.label == "Sessão mestra trabalhando…")
    state.apply(.reconnect); state.apply(.connected)
    #expect(state.phase == .listening)
    state.apply(.failure("Sem rede")); state.apply(.connected)
    state.apply(.reconnect)
    #expect(state.phase == .failed)
    #expect(state.error == "Sem rede")
    state.apply(.end)
    #expect(!state.visible)
    #expect(!state.masterWorking)
  }
  @Test func audioInterruptionRequiresExplicitResume() {
    var state = VoiceState()
    state.apply(.start); state.apply(.connected); state.apply(.interruption)
    state.apply(.speech)
    #expect(state.phase == .interrupted)
    state.apply(.resume)
    #expect(state.phase == .listening)
    state.apply(.end); state.apply(.resume)
    #expect(state.phase == .idle)
  }
  @Test func narrationCoalescesThrottlesAndYieldsToUser() {
    var narration = VoiceNarration()
    narration.offer("Lendo"); narration.offer("Conferindo uma sessão")
    #expect(narration.take(now: 1, speaking: true, userUntil: 0) == nil)
    #expect(narration.take(now: 1, speaking: false, userUntil: 2) == nil)
    #expect(narration.take(now: 2, speaking: false, userUntil: 2) == "Conferindo uma sessão")
    narration.offer("Lendo os arquivos")
    #expect(narration.take(now: 3, speaking: false, userUntil: 0) == nil)
    #expect(narration.take(now: 7, speaking: false, userUntil: 0) == "Lendo os arquivos")
    narration.offer("Concluído")
    #expect(narration.take(now: 8, speaking: false, userUntil: 0, final: true) == "Concluído")
    narration.offer("Concluído")
    #expect(narration.take(now: 20, speaking: false, userUntil: 0) == nil)
  }
  /// The master's quiet state: latest only, never the same twice, spaced by the interval, never while Alexandre
  /// speaks nor right after a spoken append.
  @Test func masterStatusSendsTheLatestChangeSpacedAndOutOfSpeech() {
    let interval = VoiceMasterStatus.interval
    var status = VoiceMasterStatus()
    status.offer("Começando")
    #expect(status.take(now: 1, userUntil: 2) == nil, "Alexandre is speaking")
    #expect(status.take(now: 2, userUntil: 2) == "Começando")
    status.offer("Consultando as sessões"); status.offer("Consultando os arquivos")
    #expect(status.take(now: 2 + interval - 1, userUntil: 0) == nil)
    #expect(status.take(now: 2 + interval, userUntil: 0) == "Consultando os arquivos")
    status.offer("Consultando as ferramentas"); status.offer("Consultando os arquivos")
    #expect(status.take(now: 100, userUntil: 0) == nil, "back to the state GPT Live already has")
    status.offer("Consultando as ferramentas")
    status.spoke(at: 99)
    #expect(status.take(now: 99 + VoiceMasterStatus.afterSpeech - 1, userUntil: 0) == nil)
    #expect(status.take(now: 99 + VoiceMasterStatus.afterSpeech, userUntil: 0) == "Consultando as ferramentas")
  }
  @Test func masterActivityIsQuietStateAndItsOwnTextIsNews() throws {
    func event(_ json: String) throws -> ConversationEvent { try JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8)) }
    let list = try event(#"{"type":"session.tool.called","data":{"name":"sessions.list"}}"#)
    #expect(VoiceMasterProgress.activity(list) == "consultando suas sessões")
    #expect(VoiceMasterProgress.describe(list) == "A mestra está consultando suas sessões.")
    let failed = try event(#"{"type":"session.tool.failed","data":{}}"#)
    #expect(VoiceMasterProgress.describe(failed) == "Uma ferramenta falhou. A mestra está verificando o resultado.")
    #expect(VoiceMasterProgress.activity(failed) == "verificando o retorno de uma ferramenta que deu erro")
    #expect(VoiceMasterProgress.activity(try event(#"{"type":"session.text.ended","data":{"text":"Achei."}}"#)) == nil)
    #expect(VoiceMasterProgress.note("consultando os arquivos")
      == "Estado do agente (para consulta; não é novidade para anunciar): consultando os arquivos. Pedido em andamento, ainda sem resultado.")
    #expect(VoiceMasterProgress.admitted(.steer) == "começando o pedido")
    #expect(VoiceMasterProgress.admitted(.queue) == "com o pedido na fila, esperando o trabalho atual")
    let frames = try VoiceProtocol.append(id: "ask-1", text: VoiceMasterProgress.note("começando o pedido"), channel: .commentary)
    #expect(try JSONDecoder().decode(JSONValue.self, from: #require(frames.first).data).object?["channel"]?.string == "commentary")
    #expect(try JSONDecoder().decode(JSONValue.self, from: #require(VoiceProtocol.append(id: "ask-1", text: "x").first).data)
      .object?["channel"]?.string == "speakable")
  }
  /// The JSON form is still read if it ever comes; on this route the queue comes from his words (`VoiceQueueIntent`).
  @Test func jsonDeliveryIsStillRead() {
    #expect(VoiceMasterRequest("Confira minha sessão").delivery == .steer)
    #expect(VoiceMasterRequest(#"{"text":"Continue depois","delivery":"queue"}"#).delivery == .queue)
    #expect(VoiceMasterRequest(#"{"text":"Agora","delivery":"invented"}"#).delivery == .steer)
  }
  @Test func progressDoesNotExposeToolArgumentsOrReasoning() throws {
    let called = try JSONDecoder().decode(ConversationEvent.self, from: Data(#"{"type":"session.tool.called","data":{"name":"session_read","input":{"sessionID":"private-id"}}}"#.utf8))
    #expect(VoiceMasterProgress.describe(called) == "A mestra está conferindo uma sessão.")
    let reasoning = try JSONDecoder().decode(ConversationEvent.self, from: Data(#"{"type":"session.reasoning.delta","data":{"delta":"private"}}"#.utf8))
    #expect(VoiceMasterProgress.describe(reasoning) == nil)
  }
  @Test func codeModeProgressUsesStructuredNestedCalls() throws {
    for tool in ["sessions.read", "opencode.session_read"] {
      let event = try JSONDecoder().decode(ConversationEvent.self, from: Data(#"{"type":"session.tool.progress","data":{"metadata":{"toolCalls":[{"tool":"\#(tool)","status":"running","input":{"sessionID":"private-id","secret":"never narrated"}}]}}}"#.utf8))
      #expect(VoiceMasterProgress.call(event)?.sessionID == "private-id")
      #expect(VoiceMasterProgress.describe(event) == "A mestra está conferindo uma sessão.")
    }
  }
  @Test func sessionToolsKeepTheirNarrationUnderCurrentAndFormerNames() throws {
    func describe(_ name: String) throws -> String? {
      VoiceMasterProgress.describe(try JSONDecoder().decode(ConversationEvent.self, from: Data(#"{"type":"session.tool.called","data":{"name":"\#(name)"}}"#.utf8)))
    }
    for (current, former, text) in [
      ("sessions.status", "mestra.session_status", "A mestra está conferindo uma sessão."),
      ("sessions.list", "mestra.sessions_list", "A mestra está consultando suas sessões."),
      ("sessions.send", "mestra.session_send", "A mestra está encaminhando seu pedido."),
      ("sessions.create", "mestra.session_create", "A mestra está criando a sessão solicitada."),
      ("sessions.wait", "mestra.session_wait", "A mestra está acompanhando o trabalho da sessão."),
      ("sessions.requests", "mestra.requests_list", "A mestra está verificando os pedidos pendentes."),
      ("sessions.answer", "mestra.request_answer", "A mestra está respondendo ao pedido autorizado."),
    ] {
      #expect(try describe(current) == text)
      #expect(try describe(former) == text)
    }
    #expect(VoiceMasterProgress.sessionTool("sessions_mark_read") == "mark_read")
    #expect(VoiceMasterProgress.sessionTool("sessions.unknown") == nil)
    // Short session tool names never shadow the native tools that share them.
    #expect(try describe("read") == "A mestra está consultando os arquivos.")
    #expect(try describe("search") == "A mestra está usando uma ferramenta.")
    #expect(VoiceMasterProgress.sessionTool("read") == nil)
  }
}
