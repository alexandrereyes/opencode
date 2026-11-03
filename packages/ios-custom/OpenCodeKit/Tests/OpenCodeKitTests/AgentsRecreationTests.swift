import Foundation
import Testing
@testable import OpenCodeKit

/// "Recriar Live Activity": the order of the swap's side effects, so the server never sees the agents activity gone
/// and a failure leaves the old one in place.
@Suite struct AgentsRecreationTests {
  struct Failure: Error {}

  /// The swap's calls, in order, and the gates a test holds open.
  final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    var calls: [String] { lock.withLock { log } }
    func record(_ call: String) { lock.withLock { log.append(call) } }
    /// Suspends until `release`, ignoring cancellation, like a request already on the wire.
    func hold() async { await withCheckedContinuation { continuation in lock.withLock { parked.append(continuation) } } }
    var holding: Bool { lock.withLock { !parked.isEmpty } }
    func release() { lock.withLock { defer { parked = [] }; return parked }.forEach { $0.resume() } }

    func steps(start: Bool = true, token: String? = "ee55", wanted: Bool = true, register: Bool = true,
      waitToken: Bool = false, waitRegister: Bool = false) -> AgentsRecreation.Steps
    {
      AgentsRecreation.Steps(
        start: {
          self.record("start")
          guard start else { throw Failure() }
          return "new"
        },
        token: { id in
          self.record("token \(id)")
          if waitToken { return await AgentsRecreation.first(within: .seconds(60)) { await self.hold(); return token } }
          return token
        },
        wanted: { id in
          self.record("wanted \(id)")
          return wanted
        },
        register: { id, token in
          self.record("register \(id) \(token)")
          if waitRegister { await self.hold() }
          guard register else { throw Failure() }
        },
        commit: { id, token in self.record("commit \(id) \(token)") },
        discard: { id in self.record("discard \(id)") },
        restore: { self.record("restore") })
    }
  }

  @Test func theNewActivityIsRegisteredBeforeTheOldOneEnds() async {
    let script = Script()
    #expect(await AgentsRecreation.swap(script.steps()) == .recreated)
    #expect(script.calls == ["start", "token new", "wanted new", "register new ee55", "commit new ee55"])
  }

  @Test func failuresBeforeTheRegistrationEndOnlyTheNewActivity() async {
    let start = Script()
    #expect(await AgentsRecreation.swap(start.steps(start: false)) == .failed(.start))
    #expect(start.calls == ["start"])

    let token = Script()
    #expect(await AgentsRecreation.swap(token.steps(token: nil)) == .failed(.token))
    #expect(token.calls == ["start", "token new", "discard new"])

    // The work ended (or the new activity did) while waiting for its token: nothing to register.
    let gone = Script()
    #expect(await AgentsRecreation.swap(gone.steps(wanted: false)) == .noWork)
    #expect(gone.calls == ["start", "token new", "wanted new", "discard new"])
  }

  @Test func aFailedRegistrationPointsTheServerBackBeforeEndingTheNewActivity() async {
    let script = Script()
    #expect(await AgentsRecreation.swap(script.steps(register: false)) == .failed(.register))
    #expect(script.calls == ["start", "token new", "wanted new", "register new ee55", "restore", "discard new"])
    #expect(!script.calls.contains { $0.hasPrefix("commit") })
  }

  @Test func leavingTheAppWhileWaitingForTheTokenCancelsWithoutRegistering() async throws {
    let script = Script()
    let swap = Task { await AgentsRecreation.swap(script.steps(waitToken: true)) }
    try await waitUntil { script.holding }
    swap.cancel()
    #expect(await swap.value == .failed(.cancelled))
    #expect(script.calls == ["start", "token new", "discard new"])
    script.release()
  }

  @Test func leavingTheAppDuringTheRegistrationStillFinishesTheSwap() async throws {
    let script = Script()
    let swap = Task { await AgentsRecreation.swap(script.steps(waitRegister: true)) }
    try await waitUntil { script.holding }
    swap.cancel()
    script.release()
    #expect(await swap.value == .recreated)
    #expect(script.calls.last == "commit new ee55")
  }

  @Test func firstReturnsTheValueOrNilOnTimeoutAndOnCancellation() async throws {
    #expect(await AgentsRecreation.first(within: .seconds(5)) { "aa" } == "aa")
    let script = Script()
    #expect(await AgentsRecreation.first(within: .milliseconds(50)) { await script.hold(); return "late" } == nil)
    script.release()
    // Cancelled while the producer ignores cancellation: it still answers at once.
    let waiting = Task { await AgentsRecreation.first(within: .seconds(60)) { await script.hold(); return "late" } }
    try await waitUntil { script.holding }
    let started = ContinuousClock.now
    waiting.cancel()
    #expect(await waiting.value == nil)
    #expect(ContinuousClock.now - started < .seconds(5))
    script.release()
  }

  @Test func outcomesSayWhatHappenedWithoutPromisingTheWatch() {
    #expect(AgentsRecreation.Outcome.recreated.succeeded && AgentsRecreation.Outcome.started.succeeded)
    #expect(!AgentsRecreation.Outcome.failed(.register).succeeded && !AgentsRecreation.Outcome.noWork.succeeded)
    #expect(AgentsRecreation.Outcome.recreated.message == "Atividade recriada. Confira o Conjunto Inteligente no relógio.")
    for failure in [AgentsRecreation.Failure.start, .token, .register, .cancelled] {
      #expect(AgentsRecreation.Outcome.failed(failure).message.hasSuffix("A atividade atual continua.")
        || AgentsRecreation.Outcome.failed(failure).message.hasSuffix("A atual continua."))
    }
  }

  /// Polls a condition the swap reaches on another task (a few milliseconds), bounded in time.
  private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw Failure() }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
