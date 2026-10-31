import Foundation
import Testing
@testable import OpenCodeKit

struct VoiceRecoveryTests {
  private func lease(_ remaining: TimeInterval) throws -> VoiceLease {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let formatter = ISO8601DateFormatter()
    let signal = VoiceSignaling()
    let body = try JSONEncoder().encode(["sessionId": signal.sessionID.uuidString, "generation": signal.generation.uuidString,
      "serverTime": formatter.string(from: start), "leaseExpiresAt": formatter.string(from: start.addingTimeInterval(remaining))])
    return try signal.parseLease(body, status: 200)
  }

  @Test func leaseStaysValidUntilTheSafetyMarginMeasuredFromTheRequest() throws {
    var clock = VoiceLeaseClock()
    #expect(clock.confirm(try lease(60), requestedAt: 100, now: 101))
    #expect(clock.validUntil == 150)
    #expect(clock.valid(at: 149.9))
    #expect(!clock.valid(at: 150))
    #expect(!clock.confirm(try lease(11), requestedAt: 100, now: 101.5))
    #expect(VoiceRecoveryPolicy.leaseMargin == 10)
  }

  @Test func onlyAnUnreachableOrOverloadedServerIsRetried() {
    #expect(VoiceLeaseClock.isTransient(URLError(.notConnectedToInternet)))
    #expect(VoiceLeaseClock.isTransient(URLError(.timedOut)))
    #expect(VoiceLeaseClock.isTransient(URLError(.networkConnectionLost)))
    for status in [408, 429, 500, 502, 503, 504, 507] {
      #expect(VoiceLeaseClock.isTransient(VoiceWireError.unavailable(status)))
      #expect(VoiceLeaseClock.isTransient(ClientError.http(status)), "the OpenCode server too")
    }
    #expect(!VoiceLeaseClock.isTransient(URLError(.cancelled)))
    // The proxy's explicit refusals: missing (404), conflicting (409) or expired (410) lease, bad request, auth.
    for status in [400, 401, 403, 404, 409, 410, 422] {
      #expect(!VoiceLeaseClock.isTransient(VoiceWireError.unavailable(status)))
    }
    #expect(!VoiceLeaseClock.isTransient(ClientError.http(404)))
    #expect(!VoiceLeaseClock.isTransient(VoiceWireError.invalidAnswer))
    #expect(!VoiceLeaseClock.isTransient(CancellationError()))
  }

  @Test func attemptsFollowTheBackoffWithinOneWindow() {
    var recovery = VoiceRecovery()
    #expect(recovery.policy.window == 120 && recovery.policy.mediaGrace == 15 && recovery.policy.handoverGrace == 3)
    #expect(recovery.next(at: 0) == nil)
    recovery.lose(at: 10)
    recovery.lose(at: 40)
    #expect(recovery.lostAt == 10)
    #expect(recovery.next(at: 10) == 1)
    #expect(recovery.next(at: 12) == 2)
    #expect(recovery.next(at: 20) == 4)
    #expect(recovery.next(at: 30) == 8)
    #expect(recovery.next(at: 45) == 15)
    #expect(recovery.next(at: 80) == 15)
    #expect(recovery.next(at: 110) == nil, "six attempts at most")
    #expect(recovery.attempts == 6)
    recovery.restore()
    #expect(!recovery.active)
    recovery.lose(at: 200)
    #expect(recovery.next(at: 319.5) == nil, "no attempt that would start after the two minutes")
    #expect(recovery.remaining(at: 319.5) == 0.5)
  }

  @Test func offlineAndReconnectingAreDistinctPhases() {
    var state = VoiceState()
    state.apply(.start)
    state.apply(.offline)
    #expect(state.phase == .connecting)
    state.apply(.connected)
    state.apply(.offline)
    #expect(state.phase == .offline)
    #expect(state.label == "Sem conexão")
    state.apply(.speech)
    #expect(state.phase == .offline)
    state.apply(.reconnect)
    #expect(state.phase == .reconnecting)
    state.apply(.offline)
    state.apply(.connected)
    #expect(state.phase == .listening, "a ready call wins over a stale offline report")
    #expect(VoiceBarState(voice: { var offline = state; offline.apply(.offline); return offline }(), elapsed: 0).label == "Sem conexão")
  }

  @Test func indicatorCoversEverySurfaceState() {
    var state = VoiceState()
    #expect(VoiceIndicator(state) == nil)
    state.apply(.start)
    #expect(VoiceIndicator(state) == .connecting)
    state.apply(.connected)
    #expect(VoiceIndicator(state) == .listening)
    state.masterWorking = true
    #expect(VoiceIndicator(state) == .working)
    state.apply(.speech)
    #expect(VoiceIndicator(state) == .speaking)
    state.apply(.interruption)
    #expect(VoiceIndicator(state) == .interrupted)
    state.apply(.reconnect)
    #expect(VoiceIndicator(state) == .reconnecting)
    state.apply(.offline)
    #expect(VoiceIndicator(state) == .offline)
    state.apply(.failure("Sem rede"))
    #expect(VoiceIndicator(state) == .failed)
    #expect(Set(VoiceIndicator.allCases.map(\.title)).count == VoiceIndicator.allCases.count)
    #expect(VoiceIndicator.allCases.allSatisfy { $0.shortTitle.count <= 18 && !$0.symbol.isEmpty })
    #expect(!VoiceIndicator.offline.animates && VoiceIndicator.reconnecting.animates)
  }
}
