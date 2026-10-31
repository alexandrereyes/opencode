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
  }
  @Test func delegationFixture() throws {
    let event = try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"ask-1","content":[{"type":"input_text","text":"Confira as sessões"}]}}"#.utf8))
    #expect(event == .delegation(id: "ask-1", text: "Confira as sessões"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.started"}"#.utf8)) == .ready)
    #expect(throws: VoiceWireError.self) { try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client"}}"#.utf8)) }
    #expect(try VoiceProtocol.decode(Data(#"{"type":"novo.evento"}"#.utf8)) == .ignored)
    // With an ID but no readable request, the delegation is answered instead of dropped.
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"ask-2","content":[]}}"#.utf8))
      == .unreadableDelegation(id: "ask-2"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"delegation.created","item":{"type":"delegation","target":"client","id":"ask-3"}}"#.utf8))
      == .unreadableDelegation(id: "ask-3"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"session.closed"}"#.utf8)) == .closed)
  }
  /// Only an expired session ends GPT Live's session; every other error leaves it open.
  @Test func onlyAnExpiredSessionEndsTheCall() throws {
    func code(_ json: String) throws -> String? {
      guard case .failure(let code) = try VoiceProtocol.decode(Data(json.utf8)) else { return "not a failure" }
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
  @Test func callContextGoesInChunksWithoutADelegation() throws {
    let text = String(repeating: "Resultado: ação concluída. ", count: 40)
    let frames = try VoiceProtocol.contextAppend(text)
    #expect(frames.count > 1)
    let parts = try frames.map { frame -> String in
      let value = try #require(JSONDecoder().decode(JSONValue.self, from: frame).object)
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
      let value = try JSONDecoder().decode(JSONValue.self, from: frame)
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
  @Test func followupsUseExplicitDeliveryOnly() {
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
