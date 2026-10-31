import Foundation
import Testing

@testable import OpenCodeKit

struct VoiceDiagnosticsTests {
  @Test func gptLiveErrorKeepsTypeCodeAndOnlyASanitizedMessage() throws {
    let event = try VoiceProtocol.decode(Data(#"""
      {"type":"error","error":{"type":"invalid_request_error","code":"unknown_event","param":"type",
      "message":"Unknown event: \"Alexandre pediu para pesquisar o preço do voo amanhã\".\nTry\u0007 again."}}
      """#.utf8))
    #expect(event == .failure(code: "invalid_request_error/unknown_event",
      detail: #"Unknown event: "…". Try again. (param: type)"#))
    // The same fields at the top level; the event's own `type` is not the error's.
    #expect(try VoiceProtocol.decode(Data(#"{"type":"error","code":"server_error","message":"Falhou."}"#.utf8))
      == .failure(code: "server_error", detail: "Falhou."))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"error","error":"Falhou."}"#.utf8))
      == .failure(code: nil, detail: "Falhou."))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"error"}"#.utf8)) == .failure(code: nil))
    #expect(VoiceFailureReason.service("invalid_request_error/unknown_event", detail: "x").summary
      == "service_error code=invalid_request_error/unknown_event")
  }

  @Test func detailTextFollowsTheServersRules() {
    #expect(VoiceDiagnosticText.sanitize(String(repeating: "x", count: 400), max: 300)
      == String(repeating: "x", count: 299) + "…")
    #expect(VoiceDiagnosticText.sanitize("Fala: “uma frase longa que alguém disse durante a chamada” e 'outra'", max: 240)
      == #"Fala: "…" e 'outra'"#)
    #expect(VoiceFailureReason.service(nil, detail: " \n ").detail == nil)
    #expect(VoiceFailureReason.service(nil, detail: String(repeating: "y", count: 500)).detail?.count == 300)
  }

  @Test func eventTypeNamesWhatCouldNotBeRead() {
    #expect(VoiceProtocol.eventType(Data(#"{"type":"turn.done","turn":{"role":"system"}}"#.utf8)) == "turn.done")
    #expect(VoiceProtocol.eventType(Data("not json".utf8)) == nil)
    #expect(VoiceFailureReason.invalidEvent("turn.done").summary == "invalid_event code=turn.done")
  }

  /// One category per way a call ends, as the server logs it.
  @Test func everyFailurePathHasItsCategory() {
    let reasons: [(VoiceFailureReason, String)] = [
      (.service(nil), "service_error"), (.invalidEvent(nil), "invalid_event"),
      (.leaseRefused(VoiceWireError.unavailable(409)), "lease_refused"), (.leaseExpired, "lease_expired"),
      (.sendFailed, "send_failed"), (.iceFailed, "ice_failed"), (.peerFailed, "peer_failed"),
      (.dataChannelClosed, "data_channel_closed"), (.mediaReset, "media_services_reset"),
      (.iceDisconnected, "ice_disconnected"), (.attemptTimeout, "attempt_timeout"), (.networkChanged, "network_changed"),
      (.audioInterrupted, "audio_interrupted"), (.userEnd, "user_end"), (.recoveryExhausted, "recovery_exhausted"),
      (.microphoneDenied, "microphone_denied"), (.delegationOverflow, "delegation_overflow"),
      (.startFailed(URLError(.timedOut)), "start_failed"), (.reconnectFailed(ClientError.http(401)), "reconnect_failed"),
    ]
    for (reason, category) in reasons { #expect(reason.category == category) }
    #expect(Set(reasons.map(\.1)).count == reasons.count)
  }

  @Test func errorCodesNameTheKindNeverTheMessage() {
    #expect(VoiceFailureReason.leaseRefused(VoiceWireError.unavailable(409)).code == "http_409")
    #expect(VoiceFailureReason.startFailed(URLError(.notConnectedToInternet)).code == "url_-1009")
    #expect(VoiceFailureReason.startFailed(ClientError.operation("Mensagem com detalhes")).code == "operation")
    #expect(VoiceFailureReason.reconnectFailed(CancellationError()).code == "cancelled")
    // Free text never survives as a code.
    #expect(VoiceFailureReason("service_error", code: "frase com espaços").code == "frasecomespaos")
    #expect(VoiceFailureReason("x", code: String(repeating: "a", count: 300)).code?.count == 120)
  }

  @Test func trailKeepsTheLastNamesBounded() {
    var trail = VoiceEventTrail()
    for index in 0..<30 { trail.record("event.\(index)") }
    trail.record("tipo com espaço")
    #expect(trail.names.count == VoiceEventTrail.capacity)
    #expect(trail.names.first == "event.7")
    #expect(trail.names.last == "tipocomespao")
  }

  @Test func reportEncodesOnlyKnownFieldsAndOmitsMissingOnes() throws {
    var trail = VoiceEventTrail()
    trail.record("delegation.created")
    let report = VoiceDiagnostic(kind: .lost, reason: .iceFailed, build: "0.1.0 (1)", at: Date(timeIntervalSince1970: 1),
      call: nil, connectedSeconds: nil, phase: "listening", recovering: false, events: trail,
      app: .init(state: .background, locked: true), audio: nil, network: nil)
    let object = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(report)).object ?? [:]
    #expect(Set(object.keys) == ["kind", "reason", "platform", "build", "at", "phase", "recovering", "events", "app"])
    #expect(object["kind"]?.string == "lost" && object["reason"]?.string == "ice_failed")
    #expect(object["at"] == .number(1000))
    let service = VoiceDiagnostic(kind: .tolerated, reason: .service("server_error", detail: "Falhou."), build: "b",
      at: Date(timeIntervalSince1970: 1), call: nil, connectedSeconds: 12, phase: "listening", recovering: false,
      events: trail, app: .init(state: .active, locked: false), audio: nil, network: nil,
      lastSent: (type: "delegation.context.append", seconds: 1.5))
    let fields = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(service)).object ?? [:]
    #expect(fields["detail"]?.string == "Falhou.")
    #expect(fields["lastSent"]?.string == "delegation.context.append")
    #expect(fields["lastSentSeconds"] == .number(1.5))
    // A report queued by an older build still decodes.
    let old = #"{"kind":"lost","reason":"ice_failed","platform":"ios","build":"b","at":1,"phase":"p","recovering":false,"events":[],"app":{"state":"active","locked":false}}"#
    #expect(try JSONDecoder().decode(VoiceDiagnostic.self, from: Data(old.utf8)).detail == nil)
  }

  @Test func outboxKeepsWhatTheServerDidNotTakeAndOnlyTheNewest() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "voice-diagnostics-\(UUID()).json")
    let outbox = VoiceDiagnosticsOutbox(url: url)
    defer { try? FileManager.default.removeItem(at: url) }
    func report(_ index: Int) -> VoiceDiagnostic {
      VoiceDiagnostic(kind: .failed, reason: .sendFailed, build: "b", at: Date(timeIntervalSince1970: Double(index)),
        call: nil, connectedSeconds: nil, phase: "listening", recovering: false, events: VoiceEventTrail(),
        app: .init(state: .active, locked: false), audio: nil, network: nil)
    }
    await outbox.add(report(1))
    await outbox.flush { _ in throw URLError(.notConnectedToInternet) }
    #expect(await outbox.pending().count == 1)
    for index in 2...25 { await outbox.add(report(index)) }
    #expect(await outbox.pending().count == VoiceDiagnosticsOutbox.limit)
    #expect(await outbox.pending().first == report(6))
    let sent = SentBatches()
    await outbox.flush { await sent.append($0.count) }
    #expect(await sent.counts == [20])
    #expect(await outbox.pending().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}

private actor SentBatches {
  var counts: [Int] = []
  func append(_ count: Int) { counts.append(count) }
}
