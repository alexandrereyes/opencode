import Foundation
import Testing

@testable import OpenCodeKit

struct VoiceDiagnosticsTests {
  @Test func gptLiveErrorKeepsTypeAndCodeButNotTheMessage() throws {
    let event = try VoiceProtocol.decode(Data(
      #"{"type":"error","error":{"type":"invalid_request_error","code":"unknown_event","message":"texto longo"}}"#.utf8))
    #expect(event == .failure(code: "invalid_request_error/unknown_event"))
    #expect(try VoiceProtocol.decode(Data(#"{"type":"error"}"#.utf8)) == .failure(code: nil))
    #expect(VoiceFailureReason.service("invalid_request_error/unknown_event").summary
      == "service_error code=invalid_request_error/unknown_event")
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
