import Foundation
import Testing
@testable import OpenCodeKit

struct VoicePreferencesTests {
  @Test func catalogHasBrazilianVoicesFirstAndUniqueWireIDs() {
    #expect(GPTLiveVoice.defaultVoice == .rio)
    #expect(GPTLiveVoice.brazilian == [.rio, .viola])
    #expect(Array(GPTLiveVoice.allCases.prefix(2)) == GPTLiveVoice.brazilian)
    #expect(GPTLiveVoice.allCases.count == 25)
    #expect(Set(GPTLiveVoice.allCases.map(\.rawValue)).count == 25)
    #expect(GPTLiveVoice.others.allSatisfy { !$0.brazilian })
    #expect(GPTLiveVoice.allCases.allSatisfy { $0.rawValue == $0.rawValue.lowercased() && $0.title == $0.rawValue.capitalized })
  }
  @MainActor @Test func devicePreferenceDefaultsToRioWithoutWritingAndPersistsExplicitChoice() throws {
    let name = "voice-preferences-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = VoicePreferences(defaults: defaults)
    #expect(preferences.voice == .rio)
    #expect(defaults.object(forKey: VoicePreferences.key) == nil)
    preferences.voice = .viola
    #expect(defaults.string(forKey: VoicePreferences.key) == "viola")
    #expect(VoicePreferences(defaults: defaults).voice == .viola)
    defaults.set("unknown-future-voice", forKey: VoicePreferences.key)
    #expect(VoicePreferences(defaults: defaults).voice == .rio)
    #expect(defaults.string(forKey: VoicePreferences.key) == "unknown-future-voice")
  }
  @Test(arguments: GPTLiveVoice.allCases) func selectedVoiceUsesThePrivateGPTLiveOutputPath(_ voice: GPTLiveVoice) throws {
    let body = try JSONDecoder().decode(JSONValue.self,
      from: #require(VoiceSignaling().offerRequest(sdp: "v=0", instructions: "Prompt de teste", voice: voice).httpBody))
    #expect(body.object?["session"]?.object?["model"]?.string == "gpt-live-1-codex")
    #expect(body.object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"]?.string == voice.rawValue)
  }
  @Test func rejectionFallsBackToRioThenCoveWithTheSameOfferAndHistory() async throws {
    let http = VoiceOfferHTTP(statuses: [400, 422, 201])
    let signal = VoiceSignaling()
    let result = try await signal.createCall(sdp: "v=0", instructions: "Prompt do servidor", voice: .maple,
      history: .init(turns: [.init(id: "test", role: .user, text: "Memória sintética", at: 0)]),
      request: { await http.respond($0) })
    #expect(result.voice == .cove)
    #expect(result.fallbackNotice == "A voz Maple não está disponível; usando Cove")
    let requests = await http.requests
    let bodies = try requests.map { try JSONDecoder().decode(JSONValue.self, from: #require($0.httpBody)) }
    #expect(bodies.map { $0.object?["session"]?.object?["audio"]?.object?["output"]?.object?["voice"]?.string } == ["maple", "rio", "cove"])
    #expect(bodies.allSatisfy { $0.object?["sdp"]?.string == "v=0" && $0.object?["session"]?.object?["initial_items"]?.array?.count == 1 })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "session-id") == signal.sessionID.uuidString })
    #expect(bodies.allSatisfy { $0.object?["session"]?.object?["instructions"]?.string == "Prompt do servidor" })
  }
  @Test func rioFallbackIsReportedOnlyAfterSuccessAndNeverRetriesTheSameRejectedVoice() async throws {
    for voice in [GPTLiveVoice.rio, .viola, .cove] {
      let http = VoiceOfferHTTP(statuses: [400, 201])
      let result = try await VoiceSignaling().createCall(sdp: "v=0", instructions: "Prompt de teste", voice: voice, request: { await http.respond($0) })
      #expect(result.voice == (voice == .rio ? .cove : .rio))
      #expect(result.fallbackNotice == "A voz \(voice.title) não está disponível; usando \(result.voice.title)")
      #expect(await http.requests.count == 2)
    }
    let http = VoiceOfferHTTP(statuses: [201])
    let result = try await VoiceSignaling().createCall(sdp: "v=0", instructions: "Prompt de teste", voice: .viola, request: { await http.respond($0) })
    #expect(result.voice == .viola && result.fallbackNotice == nil)
    #expect(await http.requests.count == 1)
  }
  @Test(arguments: [400, 401, 403, 409, 422, 429, 500, 503, 201])
  func unrelatedErrorsAndMalformedSuccessNeverRetry(_ status: Int) async throws {
    let http = VoiceOfferHTTP(statuses: [status], unrelated: true)
    await #expect(throws: VoiceWireError.self) {
      try await VoiceSignaling().createCall(sdp: "v=0", instructions: "Prompt de teste", voice: .maple, request: { await http.respond($0) })
    }
    #expect(await http.requests.count == 1)
  }
  @Test func transportFailureNeverRetries() async {
    await #expect(throws: URLError.self) {
      try await VoiceSignaling().createCall(sdp: "v=0", instructions: "Prompt de teste", voice: .maple, request: { _ in throw URLError(.timedOut) })
    }
  }
  @Test(arguments: ["invalid_voice", "unsupported_voice"])
  func explicitVoiceErrorCodesRequireAValidationStatus(_ code: String) throws {
    let data = try JSONEncoder().encode(["error": ["code": code]])
    for status in [400, 422, 500] {
      let response = try #require(HTTPURLResponse(url: VoiceSignaling.baseURL, statusCode: status, httpVersion: nil, headerFields: nil))
      #expect(VoiceSignaling.rejectsVoice(data, response: response) == (status != 500))
    }
  }
  @Test func exhaustedFallbackFailsWithoutAnotherAttempt() async {
    let http = VoiceOfferHTTP(statuses: [400, 400, 400])
    await #expect(throws: VoiceWireError.unavailable(400)) {
      try await VoiceSignaling().createCall(sdp: "v=0", instructions: "Prompt de teste", voice: .maple, request: { await http.respond($0) })
    }
    #expect(await http.requests.count == 3)
  }
  @Test func cancellationAfterRejectionDoesNotStartFallback() async {
    let http = VoiceOfferHTTP(statuses: [400, 201])
    let task = Task {
      try await VoiceSignaling().createCall(sdp: "v=0", instructions: "Prompt de teste", voice: .viola, request: { request in
        let response = await http.respond(request)
        withUnsafeCurrentTask { $0?.cancel() }
        return response
      })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await http.requests.count == 1)
  }
}

private actor VoiceOfferHTTP {
  let statuses: [Int]
  let unrelated: Bool
  var requests: [URLRequest] = []
  init(statuses: [Int], unrelated: Bool = false) { self.statuses = statuses; self.unrelated = unrelated }
  func respond(_ request: URLRequest) -> (Data, URLResponse) {
    let status = statuses[min(requests.count, statuses.count - 1)]
    requests.append(request)
    let body = unrelated ? #"{"error":{"type":"invalid_request_error","param":"sdp","code":"invalid_value"}}"#
      : status == 201 ? "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
      : status == 422 ? #"{"detail":[{"loc":["body","session","audio","output","voice"],"type":"enum"}]}"#
      : #"{"error":{"type":"invalid_request_error","param":"session.audio.output.voice","code":"unsupported_value"}}"#
    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
      headerFields: status == 201 ? ["Location": "/v1/live/test"] : nil)!)
  }
}
