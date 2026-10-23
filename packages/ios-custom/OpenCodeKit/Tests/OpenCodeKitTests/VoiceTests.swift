import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceTests {
  @Test func signalingDoesNotCarryCredentials() throws {
    let signal = VoiceSignaling()
    let request = try signal.offerRequest(sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n")
    #expect(request.url?.host == "llm-proxy-svc")
    #expect(request.url?.path == "/backend-api/codex/realtime/calls")
    #expect(request.url?.query == "intent=quicksilver&architecture=avas")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "x-gpt-live-generation") == signal.generation.uuidString)
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    #expect(body.object?["session"]?.object?["model"]?.string == "gpt-live-1-codex")
    #expect(body.object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"]?.string == "cove")
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
    let event = try JSONDecoder().decode(ConversationEvent.self, from: Data(#"{"type":"session.tool.progress","data":{"metadata":{"toolCalls":[{"tool":"opencode.session_read","status":"running","input":{"sessionID":"private-id","secret":"never narrated"}}]}}}"#.utf8))
    #expect(VoiceMasterProgress.call(event)?.sessionID == "private-id")
    #expect(VoiceMasterProgress.describe(event) == "A mestra está conferindo uma sessão.")
  }
}
