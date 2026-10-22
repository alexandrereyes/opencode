import Foundation
import Testing

@testable import OpenCodeKit

private let quotaNow = Subscriptions.date("2026-09-10T12:00:00Z")!
private func quotaAccount(_ id: String = "a", plan: String? = "pro", remaining: Double? = 5,
                          capacity: Bool? = true) -> Subscriptions.Account {
  .init(id: id, name: "Conta " + id, plan: plan, remaining: remaining,
        observedAt: "2026-09-10T08:00:00Z", hasCapacity: capacity)
}
private func project(_ accounts: [Subscriptions.Account], plan: String = "pro") -> SubscriptionProjection {
  SubscriptionProjection(accounts: accounts, plan: plan, now: quotaNow)
}

@Test func fullSanitizedSubscriptionSnapshotAndNullableUnknownFields() throws {
  struct Envelope: Decodable { let output: Subscriptions }
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/subscriptions-pools.json")
  let data = try Data(contentsOf: url)
  let info = try JSONDecoder().decode(Envelope.self, from: data).output
  #expect(info.accounts.count == 5)
  #expect(info.anthropic.accounts.count == 7)
  #expect(info.automation?.enabled == false)
  #expect(info.accounts.first?.bankedResets?.available == 2)
  #expect(info.accounts.first?.credits == 54947.502038)
  #expect(info.accounts.first?.fiveHourRemaining == 0)
  #expect(info.accounts[1].remaining == nil)
  #expect(Subscriptions.date(info.accounts.first?.observedAt) != nil)
  let now = Subscriptions.date("2026-10-22T17:00:00Z")!
  let claude = SubscriptionProjection(accounts: info.anthropic.accounts, plan: "max20x", now: now)
  #expect(claude.equivalents == 0.97)
  #expect(claude.remaining == 48.5)
  #expect(claude.fiveHourRemaining == 89.5)
  #expect(claude.ready == 1)
  for status in ["unconfigured", "unavailable", "future-status"] {
    let json = #"{"status":"STATUS","accounts":[],"anthropic":{"status":"disabled","accounts":[]},"future":{"x":1}}"#.replacingOccurrences(of: "STATUS", with: status)
    let value = try JSONDecoder().decode(Subscriptions.self, from: Data(json.utf8))
    #expect(value.status == status)
    #expect(value.automation == nil)
    #expect(value.anthropic.status == "disabled")
  }
  var account = quotaAccount(plan: "unknown-tier", remaining: nil, capacity: nil)
  account.bankedResets = nil
  account.credits = nil
  #expect(try JSONDecoder().decode(Subscriptions.Account.self, from: JSONEncoder().encode(account)).plan == "unknown-tier")
}

@Test func subscriptionPoolMembershipUnweightedEquivalentsAndFixedDenominator() {
  var disabled = quotaAccount("disabled", remaining: 100); disabled.enabled = false
  var unauthenticated = quotaAccount("unauthenticated", remaining: 100); unauthenticated.authenticated = false
  let accounts = [quotaAccount(remaining: 80), quotaAccount("max", plan: "promax", remaining: 40),
                  quotaAccount("empty", remaining: 0, capacity: false), quotaAccount("plus", plan: "plus", remaining: 100),
                  quotaAccount("lite", plan: "prolite", remaining: 100), disabled, unauthenticated]
  let pool = project(accounts)
  #expect(pool.total == 3 && pool.ready == 2 && pool.measured == 3)
  #expect(pool.equivalents == 1.2 && pool.remaining == 40)
  #expect(project([quotaAccount(remaining: 36), quotaAccount("b", remaining: 0, capacity: false)]).remaining == 18)
  #expect(project([quotaAccount(remaining: 80), quotaAccount("b", remaining: 70)]).equivalents == 1.5)
  #expect(project([quotaAccount(remaining: 100), quotaAccount("b", remaining: 100)]).equivalents == 2)
  #expect(project([quotaAccount(remaining: 0, capacity: false)]).equivalents == 0)
  #expect(project([quotaAccount(plan: "promax", remaining: 80)], plan: "promax").equivalents == 0.8)
  #expect(project([quotaAccount(plan: "promax")], plan: "prolite").total == 0)
  #expect(project([quotaAccount(plan: "max20x", remaining: 31), quotaAccount("b", plan: "max5x")], plan: "max20x").equivalents == 0.31)
}

@Test func subscriptionCapacityNotRoundedQuotaAndUnknownWholePoolSuppression() {
  #expect(project([quotaAccount(remaining: 0)]).ready == 1)
  #expect(project([quotaAccount(remaining: 0.001)]).ready == 1)
  #expect(SubscriptionFormat.percent(0.001) == "0%")
  #expect(SubscriptionFormat.percent(59.5) == "60%")
  #expect(quotaAccount(remaining: nil).capacity(at: quotaNow) == .available)
  var cooling = quotaAccount(remaining: 36); cooling.cooldownSeconds = 120
  let noReady = project([cooling, quotaAccount("b", remaining: 54, capacity: false)])
  #expect(noReady.equivalents == 0.9 && noReady.remaining == 45 && noReady.ready == 0 && noReady.balance == .unavailable)
  var stale = quotaAccount(); stale.stale = true
  for unknown in [stale, quotaAccount(remaining: nil), quotaAccount(capacity: nil)] {
    let pool = project([quotaAccount(), unknown])
    #expect(pool.equivalents == nil && pool.remaining == nil && pool.balance == .unknown)
  }
  let empty = project([])
  #expect(empty.balance == .empty && empty.equivalents == nil && empty.remaining == nil && empty.inventory == nil)
}

@Test func subscriptionBothRenewalBoundariesAndMissingObservation() {
  for plan in ["pro", "promax", "prolite", "plus", "max20x", "max5x"] {
    for fiveHour in [false, true] {
      var account = quotaAccount(plan: plan)
      if fiveHour { account.fiveHourResetAt = "2026-09-10T09:00:00Z" }
      if !fiveHour { account.resetAt = "2026-09-10T09:00:00Z" }
      #expect(account.capacity(at: quotaNow) == .unconfirmed)
      #expect(project([account], plan: plan).ready == 0)
      #expect(project([account], plan: plan).equivalents == nil)
      #expect(account.capacity(at: Subscriptions.date("2026-09-10T08:30:00Z")!) == .available)
      account.observedAt = nil
      #expect(account.capacity(at: quotaNow) == .available)
      account.observedAt = "2026-09-10T09:00:00Z"
      #expect(account.capacity(at: quotaNow) == .available)
    }
  }
  #expect(quotaAccount(plan: "team").capacity(at: quotaNow) == .outside)
}

@Test func subscriptionFiveHourIndependenceInventoryAndOldestObservation() {
  var first = quotaAccount(remaining: 72, capacity: false)
  first.plan = "plus"; first.fiveHourRemaining = 0
  first.bankedResets = .init(available: 2, earliestExpiresAt: "2026-10-01T12:00:00Z", latestExpiresAt: "2026-10-02T12:00:00Z")
  var second = quotaAccount("b", plan: "plus", remaining: 0, capacity: false)
  second.fiveHourRemaining = 85
  second.observedAt = "2026-09-10T07:00:00Z"
  second.bankedResets = .init(available: 3, earliestExpiresAt: "2026-10-03T12:00:00Z", latestExpiresAt: "2026-10-05T12:00:00Z", nonExpiring: 1)
  var third = quotaAccount("c", plan: "plus", remaining: 48); third.fiveHourRemaining = 60
  let pool = project([first, second, third], plan: "plus")
  #expect(pool.remaining == 40 && pool.fiveHourRemaining == 145 / 3 && pool.ready == 1)
  #expect(pool.observedAt == Subscriptions.date(second.observedAt))
  #expect(pool.inventory == nil)
  let inventory = project([first, second], plan: "plus").inventory
  #expect(inventory?.available == 5 && inventory?.nonExpiring == 1)
  #expect(inventory?.earliest == Subscriptions.date(first.bankedResets?.earliestExpiresAt))
  #expect(inventory?.latest == Subscriptions.date(second.bankedResets?.latestExpiresAt))
  third.remaining = nil
  #expect(project([third], plan: "plus").fiveHourRemaining == 60)
  third.hasCapacity = nil
  #expect(project([third], plan: "plus").fiveHourRemaining == 60)
  third.stale = true
  #expect(project([third], plan: "plus").fiveHourRemaining == nil)
}

@Test func subscriptionWeeklyPaceAndInvalidBoundaries() {
  var half = quotaAccount(); half.resetAt = "2026-09-14T00:00:00Z"
  var full = half; full.resetAt = "2026-09-17T12:00:00Z"
  var cooling = half; cooling.cooldownSeconds = 60
  var unavailable = half; unavailable.hasCapacity = false
  #expect(half.pace(at: quotaNow) == 50 && full.pace(at: quotaNow) == 100)
  #expect(project([half, full, cooling, unavailable]).expectedRemaining == 62.5)
  for date in [nil, "invalid", "2026-09-10T12:00:00Z", "2026-09-18T12:00:00Z"] {
    var invalid = half; invalid.resetAt = date
    #expect(project([half, invalid]).expectedRemaining == nil)
  }
  half.remaining = nil
  #expect(half.pace(at: quotaNow) == nil)
}

@Test func subscriptionStablePlanThenCapacityOrderingAndStatePrecedence() {
  var stale = quotaAccount("stale"); stale.stale = true
  var cooling = quotaAccount("cooldown"); cooling.cooldownSeconds = 120
  let accounts = [quotaAccount("other", plan: "team"), quotaAccount("plus", plan: "plus"), quotaAccount("lite", plan: "prolite"),
                  stale, quotaAccount("available"), cooling, quotaAccount("unknown", capacity: nil),
                  quotaAccount("exhausted", capacity: false), quotaAccount("second"), quotaAccount("max", plan: "promax", capacity: false)]
  #expect(SubscriptionProjection.sorted(accounts, now: quotaNow).map(\.id) == ["max", "available", "second", "stale", "cooldown", "unknown", "exhausted", "lite", "plus", "other"])
  var account = quotaAccount(remaining: 0, capacity: false)
  account.fiveHourRemaining = 0
  #expect(account.state(at: quotaNow) == .weeklyExhausted)
  account.remaining = 72
  #expect(account.state(at: quotaNow) == .fiveHourExhausted)
  account.fiveHourRemaining = 20
  #expect(account.state(at: quotaNow) == .noCapacity)
  account.plan = "free"
  #expect(account.state(at: quotaNow) == .outside)
  account.plan = "pro"; account.stale = true
  #expect(account.state(at: quotaNow) == .unconfirmed)
  account.cooldownSeconds = 1
  #expect(account.state(at: quotaNow) == .cooldown)
  account.authenticated = false
  #expect(account.state(at: quotaNow) == .reauthenticate)
  account.enabled = false
  #expect(account.state(at: quotaNow) == .disabled)
  #expect(SubscriptionFormat.tone(9.99) == .danger && SubscriptionFormat.tone(10) == .warning && SubscriptionFormat.tone(30) == .neutral)
}

@MainActor @Test func subscriptionSelectionIsLocalPerServerProviderAndReconcilesMissingIDs() {
  let suite = "proxy-selection-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let a = SubscriptionSelection(server: "http://a", defaults: defaults)
  let b = SubscriptionSelection(server: "http://b", defaults: defaults)
  a.toggle("a", provider: .codex); a.toggle("c", provider: .anthropic)
  b.toggle("b", provider: .codex)
  #expect(a.selected(.codex) == "a" && a.selected(.anthropic) == "c" && b.selected(.codex) == "b")
  #expect(SubscriptionSelection(server: "http://a", defaults: defaults).selected(.codex) == "a")
  a.toggle("a", provider: .codex)
  #expect(a.selected(.codex) == nil)
  a.reconcile([], provider: .anthropic)
  #expect(a.selected(.anthropic) == nil && b.selected(.codex) == "b")
}

private actor QuotaClient: SubscriptionClient {
  var value = Subscriptions(status: "ok", accounts: [quotaAccount()], automation: .init(enabled: false))
  var reads = 0
  var writes = 0
  var error: String?
  var hold = false
  var readGate: CheckedContinuation<Void, Never>?
  var writeGate: CheckedContinuation<Void, Never>?
  func configure(error: String? = nil, hold: Bool = false) { self.error = error; self.hold = hold }
  func subscriptions() async throws -> Subscriptions {
    reads += 1
    if hold { await withCheckedContinuation { readGate = $0 } }
    if error == "read" { throw ClientError.rpc("rpc.method_not_found") }
    return value
  }
  func releaseRead() { readGate?.resume(); readGate = nil }
  func releaseWrite() { writeGate?.resume(); writeGate = nil }
  func setSubscriptionAutomation(_ provider: SubscriptionProvider, enabled: Bool) async throws -> Subscriptions.Automation {
    writes += 1
    if hold { await withCheckedContinuation { writeGate = $0 } }
    if let error { throw ClientError.rpc(error) }
    value.automation = .init(enabled: enabled)
    return .init(enabled: enabled)
  }
  func consumeSubscriptionReset(_ provider: SubscriptionProvider, accountID: String) async throws -> SubscriptionResetResult {
    writes += 1
    if hold { await withCheckedContinuation { writeGate = $0 } }
    if let error { throw ClientError.rpc(error) }
    return .init(code: "ok", windowsReset: 1)
  }
}

private actor QuotaSleeper {
  var gate: CheckedContinuation<Void, any Error>?
  var ticks = 0
  func sleep() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { gate = $0; ticks += 1 }
    } onCancel: { Task { await self.cancel() } }
  }
  func advance() { gate?.resume(); gate = nil }
  func cancel() { gate?.resume(throwing: CancellationError()); gate = nil }
}

@MainActor private func settle(_ condition: @escaping () async -> Bool) async {
  for _ in 0..<10_000 {
    if await condition() { return }
    await Task.yield()
  }
  Issue.record("Condition did not settle")
}

@MainActor @Test func subscriptionStoreDeduplicatesDueRefreshAndForegroundPolling() async {
  let client = QuotaClient()
  let sleeper = QuotaSleeper()
  let store = SubscriptionStore(server: "test", client: client,
    clock: .init(now: { quotaNow }, sleep: { _ in try await sleeper.sleep() }))
  await client.configure(hold: true)
  store.start(); store.start()
  await settle { await client.reads == 1 }
  let manual = Task { await store.refresh() }
  await Task.yield()
  #expect(store.loading)
  await client.releaseRead()
  await manual.value
  await settle { await sleeper.ticks == 1 }
  #expect(await client.reads == 1)
  await store.refresh(ifDue: true)
  #expect(await client.reads == 1)
  await client.configure()
  await sleeper.advance()
  await settle { await client.reads == 2 }
  await store.stop()
  #expect(!store.loading)
  await sleeper.advance()
  #expect(await client.reads == 2)
  store.start()
  await settle { await client.reads == 3 }
  await store.stop()
}

@MainActor @Test func subscriptionStoreDiscardsCancelledOldServerReadAndExposesFailure() async {
  let client = QuotaClient()
  await client.configure(hold: true)
  let old = SubscriptionStore(server: "old", client: client)
  let read = Task { await old.refresh() }
  await settle { await client.reads == 1 }
  let stop = Task { await old.stop() }
  await Task.yield()
  await client.releaseRead()
  await stop.value; await read.value
  #expect(old.snapshot == nil)
  let new = SubscriptionStore(server: "new", client: client)
  #expect(new.snapshot == nil)
  await client.configure(error: "read")
  await new.refresh()
  #expect(new.snapshot?.status == "unavailable" && new.readError != nil)
  await client.configure()
  await new.refresh()
  #expect(new.snapshot?.status == "ok" && new.readError == nil)
}

@MainActor @Test func subscriptionActionsRequireConfirmationPendingSuccessAndRefetch() async {
  let client = QuotaClient()
  let store = SubscriptionStore(server: "test", client: client)
  await store.refresh()
  store.requestAutomation(.codex, enabled: true)
  #expect(await client.writes == 0 && store.pending.isEmpty)
  store.confirmation = nil
  await store.confirm()
  #expect(await client.writes == 0)
  await client.configure(hold: true)
  store.requestAutomation(.codex, enabled: true)
  let action = Task { await store.confirm() }
  await settle { await client.writes == 1 }
  #expect(store.pending[.codex] == true)
  store.requestAutomation(.codex, enabled: false)
  #expect(store.confirmation == nil)
  await client.configure()
  await client.releaseWrite()
  await action.value
  #expect(store.snapshot?.automation?.enabled == true && store.pending.isEmpty)
  #expect(await client.reads == 2)
  var account = quotaAccount(); account.bankedResets = .init(available: 2)
  store.requestReset(.codex, account: account)
  #expect(await client.writes == 1)
  await store.confirm()
  #expect(await client.writes == 2)
  #expect(await client.reads == 3)
  #expect(store.feedback?.failure == false && store.resetting.isEmpty)
}

@MainActor @Test func subscriptionEveryTypedActionFailureRefetchesAndClearsPending() async {
  for type in ["no_credit", "busy", "consume_failed", "rpc.method_not_found"] {
    let client = QuotaClient()
    let store = SubscriptionStore(server: "test", client: client)
    await store.refresh()
    await client.configure(error: type, hold: true)
    var account = quotaAccount(); account.bankedResets = .init(available: 1)
    store.requestReset(.codex, account: account)
    let task = Task { await store.confirm() }
    await settle { await client.writes == 1 }
    #expect(store.resetting.contains("codex:a"))
    store.requestReset(.codex, account: account)
    #expect(store.confirmation == nil)
    await client.configure(error: type)
    await client.releaseWrite()
    await task.value
    #expect(store.feedback?.text == SubscriptionActionFailure.classify(ClientError.rpc(type), automation: false).localizedDescription)
    #expect(store.resetting.isEmpty && store.feedback?.failure == true)
    #expect(await client.reads == 2)
  }
  let client = QuotaClient()
  let store = SubscriptionStore(server: "test", client: client)
  await store.refresh()
  await client.configure(error: "update_failed")
  store.requestAutomation(.codex, enabled: true)
  await store.confirm()
  #expect(store.pending.isEmpty && store.snapshot?.automation?.enabled == false)
  #expect(store.feedback?.text == SubscriptionActionFailure.updateFailed.localizedDescription)
  #expect(await client.reads == 2)
}

@Test func subscriptionActionWireContractAndLongResetTimeoutWithFakeTransport() async throws {
  let client = OpenCodeClient(configuration: .init(url: URL(string: "http://unit.invalid")!, password: "fake")) { request in
    #expect(request.url?.query == nil)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") != nil)
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
    #expect(body.object?["input"]?.object?["provider"]?.string == "anthropic")
    let response: String
    if request.url?.path.hasSuffix("consumeReset") == true {
      #expect(request.timeoutInterval >= 100)
      #expect(body.object?["input"]?.object?["accountId"]?.string == "a/b")
      response = #"{"output":{"code":"ok","windowsReset":2}}"#
    } else {
      #expect(body.object?["input"]?.object?["enabled"] == .bool(true))
      response = #"{"output":{"enabled":true}}"#
    }
    return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
  #expect(try await client.setSubscriptionAutomation(.anthropic, enabled: true).enabled)
  #expect(try await client.consumeSubscriptionReset(.anthropic, accountID: "a/b").windowsReset == 2)
}

@MainActor @Test func subscriptionRetainsSameServerWhileRefreshingButNotAfterFailure() async {
  let client = QuotaClient()
  let store = SubscriptionStore(server: "test", client: client)
  await store.refresh()
  await client.configure(error: "read", hold: true)
  let refresh = Task { await store.refresh() }
  await settle { await client.reads == 2 }
  #expect(store.loading && store.snapshot?.status == "ok")
  await client.releaseRead()
  await refresh.value
  #expect(!store.loading && store.snapshot?.status == "unavailable")
}

@MainActor @Test func subscriptionServerSwitchDiscardsPendingActionAndSelectionSurvivesFailure() async {
  let suite = "proxy-store-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let client = QuotaClient()
  let store = SubscriptionStore(server: "old", client: client, defaults: defaults)
  await store.refresh()
  store.toggleSelection(quotaAccount(), provider: .codex)
  await client.configure(error: "read")
  await store.refresh()
  #expect(store.selectedIDs[.codex] == "a")
  await client.configure()
  await store.refresh()
  await client.configure(hold: true)
  store.requestAutomation(.codex, enabled: true)
  let action = Task { await store.confirm() }
  await settle { await client.writes == 1 }
  let stop = Task { await store.stop() }
  await settle { store.pending.isEmpty }
  await client.configure()
  await client.releaseWrite()
  await stop.value; await action.value
  #expect(store.feedback == nil && store.snapshot?.automation?.enabled == false)
  let new = SubscriptionStore(server: "new", client: client, defaults: defaults)
  #expect(new.snapshot == nil && new.selectedIDs.isEmpty)
}
