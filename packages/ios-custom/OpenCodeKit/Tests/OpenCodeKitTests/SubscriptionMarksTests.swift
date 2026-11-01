import Foundation
import Testing

@testable import OpenCodeKit

private let marksNow = Subscriptions.date("2026-11-01T11:40:00Z")!
private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

private func markAccount(_ id: String, plan: String?, weekly: Double? = nil, fiveHour: Double? = nil,
                         fiveHourResetAt: String? = nil, capacity: Bool? = true, cooldown: Double = 0,
                         stale: Bool = false, enabled: Bool = true, authenticated: Bool = true,
                         observedAt: String = "2026-11-01T11:35:00Z", resetAt: String? = "2026-11-05T14:00:00Z") -> Subscriptions.Account {
  .init(id: id, name: "Conta " + id, enabled: enabled, authenticated: authenticated, plan: plan, remaining: weekly,
        resetAt: weekly == nil ? nil : resetAt, fiveHourRemaining: fiveHour, fiveHourResetAt: fiveHourResetAt,
        observedAt: observedAt, stale: stale, hasCapacity: capacity, cooldownSeconds: cooldown)
}

@Test func claudeShowsEveryPlanWithOneMarkPerAccountAndASupportedRelease() {
  let marks = SubscriptionMarks(accounts: [
    markAccount("a", plan: "max5x", fiveHour: 100),
    markAccount("b", plan: "max5x", fiveHour: 100),
    markAccount("c", plan: "max5x", fiveHour: 92, fiveHourResetAt: "2026-11-01T14:19:00Z"),
    markAccount("d", plan: "max5x", fiveHour: 69, fiveHourResetAt: "2026-11-01T13:39:00Z"),
    markAccount("e", plan: "max5x", fiveHour: 0, fiveHourResetAt: "2026-11-01T13:30:00Z", capacity: false, cooldown: 6560),
    markAccount("f", plan: "max20x", weekly: 0, capacity: false, resetAt: "2026-11-05T14:00:00Z"),
    markAccount("g", plan: "max20x", weekly: 0, capacity: false, resetAt: "2026-11-03T12:00:00Z"),
  ], now: marksNow)
  #expect(marks.groups.map(\.label) == ["5x", "20x"])
  #expect(marks.groups.map(\.title) == ["Max 5x", "Max 20x"])
  #expect(marks.groups[0].accounts.map(\.mark) == [.ready, .ready, .ready, .ready,
    .blocked(until: Subscriptions.date("2026-11-01T13:30:00Z"))])
  #expect(marks.groups[1].accounts.map(\.mark) == [.exhausted, .exhausted])
  #expect(marks.ready == 4)
  #expect(marks.total == 7)
  // The weekly renewals of the exhausted accounts never become a release time.
  #expect(marks.release == .init(count: 1, at: Subscriptions.date("2026-11-01T13:30:00Z")!))
  #expect(marks.summary(now: marksNow, calendar: utc) == "4 prontas · +1 às 13:30")
  #expect(marks.summary(now: marksNow, calendar: utc, compact: true) == "4 prontas · +1 13:30")
  #expect(marks.summary(now: marksNow, calendar: utc, release: false) == "4 prontas")
  #expect(marks.count(.exhausted) == 2 && marks.groups[1].unmeasured == false)
  #expect(marks.spoken("Claude", now: marksNow, calendar: utc)
    == "Claude, 4 de 7 assinaturas prontas agora. Max 5x: 4 prontas, 1 parada. Max 20x: 2 com a semana esgotada. Mais 1 às 13:30 volta")
}

@Test func codexKeepsUnmeasuredAccountsApartAndIncludesThePinnedOneAmongTheOthers() {
  let marks = SubscriptionMarks(accounts: [
    markAccount("iris", plan: "promax", weekly: 81),
    markAccount("lume", plan: "free"),
    markAccount("kauri", plan: "prolite", weekly: 54, fiveHour: 0, fiveHourResetAt: "2026-11-01T14:15:00Z", capacity: false),
    markAccount("jade", plan: "prolite", weekly: 0, capacity: false),
    markAccount("mira", plan: "free"),
  ], pinned: "iris", now: marksNow)
  #expect(marks.groups.map(\.label) == ["Pro Max", "5x", "Free"])
  #expect(marks.spoken("Codex", now: marksNow, calendar: utc).contains("Free: 2 sem medição"))
  #expect(marks.groups[0].accounts.map(\.pinned) == [true])
  #expect(marks.groups[1].accounts.map(\.mark) == [.blocked(until: Subscriptions.date("2026-11-01T14:15:00Z")), .exhausted])
  // Accepted by the proxy but never measured: not ready, not exhausted.
  #expect(marks.groups[2].accounts.map(\.mark) == [.unmeasured, .unmeasured])
  #expect(marks.groups[2].unmeasured)
  #expect(marks.ready == 1)
  #expect(marks.summary(now: marksNow, calendar: utc) == "1 pronta · +1 às 14:15")
}

@Test func unknownIsNeverZeroAndThePermissionWinsOverARoundedPercent() {
  let at = { (account: Subscriptions.Account) in SubscriptionMark(account, now: marksNow) }
  #expect(at(markAccount("stale", plan: "max5x", fiveHour: 80, stale: true)) == .unmeasured)
  #expect(at(markAccount("nil", plan: "max5x", fiveHour: 80, capacity: nil)) == .unmeasured)
  #expect(at(markAccount("windows", plan: "plus", capacity: true)) == .unmeasured)
  // A 5-hour renewal that passed after the last observation makes the measurement old.
  #expect(at(markAccount("passed", plan: "max5x", fiveHour: 0, fiveHourResetAt: "2026-11-01T11:38:00Z", capacity: false)) == .unmeasured)
  #expect(at(markAccount("rounded", plan: "pro", weekly: 0, capacity: true)) == .ready)
  #expect(at(markAccount("login", plan: "pro", weekly: 50, authenticated: false)) == .attention)
}

@Test func aReleaseNeedsAnEndForEveryKnownBlocker() {
  let at = { (account: Subscriptions.Account) in SubscriptionMark(account, now: marksNow) }
  // A refusal the windows do not explain has no time.
  #expect(at(markAccount("refused", plan: "pro", weekly: 40, fiveHour: 30, capacity: false)) == .blocked(until: nil))
  // A 5-hour window at zero without its reset time cannot promise the wait's end either.
  #expect(at(markAccount("no-reset", plan: "pro", weekly: 40, fiveHour: 0, capacity: false, cooldown: 600)) == .blocked(until: nil))
  #expect(at(markAccount("wait", plan: "pro", weekly: 40, fiveHour: 30, cooldown: 600))
    == .blocked(until: marksNow.addingTimeInterval(600)))
  #expect(at(markAccount("both", plan: "pro", weekly: 40, fiveHour: 0, fiveHourResetAt: "2026-11-01T13:00:00Z", capacity: false, cooldown: 600))
    == .blocked(until: Subscriptions.date("2026-11-01T13:00:00Z")))
  // A wait on a stale measurement trusts only the wait.
  #expect(at(markAccount("stale-wait", plan: "pro", weekly: 40, fiveHour: 0, fiveHourResetAt: "2026-11-01T13:00:00Z", capacity: false, cooldown: 600, stale: true))
    == .blocked(until: marksNow.addingTimeInterval(600)))
}

@Test func disabledAccountsStayOutAndUnknownPlansKeepTheirProxyName() {
  let marks = SubscriptionMarks(accounts: [
    markAccount("off", plan: "max5x", fiveHour: 90, enabled: false),
    markAccount("team", plan: "team", weekly: 70),
    markAccount("none", plan: nil, weekly: 70),
  ], now: marksNow)
  #expect(marks.total == 2)
  #expect(marks.groups.map(\.label) == ["Team", "Outro"])
  #expect(marks.groups.map(\.title) == ["Team", "Plano desconhecido"])
}

@Test func summariesSayWhatTheProviderHasInsteadOfZero() {
  #expect(SubscriptionMarks(accounts: [], now: marksNow).summary(now: marksNow) == "nenhuma conta")
  #expect(SubscriptionMarks(accounts: [markAccount("a", plan: "free"), markAccount("b", plan: "free")], now: marksNow)
    .summary(now: marksNow) == "sem medição")
  let tomorrow = SubscriptionMarks(accounts: [
    markAccount("x", plan: "pro", weekly: 30, fiveHour: 30, cooldown: 86_400),
    markAccount("y", plan: "pro", weekly: 30, fiveHour: 30, cooldown: 86_430),
  ], now: marksNow)
  #expect(tomorrow.summary(now: marksNow, calendar: utc) == "0 prontas · +2 02/11 11:40")
}

@Test func eachReadyAccountShowsTheBalanceOfItsLimitingWindowAndNothingElseShowsANumber() {
  let marks = SubscriptionMarks(accounts: [
    markAccount("both", plan: "max5x", weekly: 72, fiveHour: 100),
    markAccount("five", plan: "max5x", fiveHour: 100),
    markAccount("week", plan: "max5x", weekly: 99.6),
    markAccount("zero", plan: "max5x", weekly: 0, capacity: true),
    markAccount("stopped", plan: "max5x", weekly: 58, fiveHour: 0, fiveHourResetAt: "2026-11-01T13:30:00Z", capacity: false),
    markAccount("stale", plan: "max5x", weekly: 80, stale: true),
    markAccount("empty", plan: "max20x", weekly: 0, capacity: false),
  ], now: marksNow)
  let balances = Dictionary(uniqueKeysWithValues: marks.groups.flatMap(\.accounts).map { ($0.id, $0.balance) })
  #expect(balances["both"]! == .init(percent: 72, window: .weekly, alone: false))
  #expect(balances["five"]! == .init(percent: 100, window: .fiveHour, alone: true))
  #expect(balances["week"]! == .init(percent: 100, window: .weekly, alone: true))
  // The proxy still serves a rounded 0%: the number says 0, not unknown.
  #expect(balances["zero"]! == .init(percent: 0, window: .weekly, alone: true))
  #expect(balances["stopped"]! == nil && balances["stale"]! == nil && balances["empty"]! == nil)
  #expect(balances["five"]!!.spoken == "100% em 5 horas (semana não informada)")
  #expect(balances["both"]!!.spoken == "72% na semana")
}

@Test func theStripPutsReadyAccountsFirstAndRepeatsAPlanWhenStatesSplitIt() {
  let marks = SubscriptionMarks(accounts: [
    markAccount("a-wait", plan: "max5x", fiveHour: 0, fiveHourResetAt: "2026-11-01T14:00:00Z", capacity: false),
    markAccount("a-9", plan: "max5x", fiveHour: 9),
    markAccount("b-off", plan: "max20x", weekly: 0, capacity: false),
    markAccount("a-100", plan: "max5x", fiveHour: 100),
    markAccount("b-64", plan: "max20x", weekly: 64),
    markAccount("a-soon", plan: "max5x", fiveHour: 0, fiveHourResetAt: "2026-11-01T12:00:00Z", capacity: false),
    markAccount("a-100b", plan: "max5x", fiveHour: 100),
    markAccount("free", plan: "free"),
    markAccount("login", plan: "max20x", weekly: 50, authenticated: false),
    markAccount("a-why", plan: "max5x", weekly: 40, fiveHour: 30, capacity: false),
  ], pinned: "a-9", now: marksNow)
  #expect(marks.runs.map(\.label) == ["5x", "20x", "5x", "20x", "Free"])
  #expect(marks.runs.map { $0.accounts.map(\.id) } == [
    // Larger balance first within the plan; equal ones keep the proxy's order.
    ["a-100", "a-100b", "a-9"], ["b-64"],
    // Stopped ones by release, the unexplained one last; then exhausted, login and unmeasured.
    ["a-soon", "a-wait", "a-why"], ["b-off", "login"], ["free"],
  ])
  #expect(Set(marks.runs.map(\.id)).count == marks.runs.count)
  // Groups, which the details read, keep the plans whole in the proxy's order.
  #expect(marks.groups.map(\.label) == ["5x", "20x", "Free"])
  #expect(marks.runs[0].accounts.map(\.pinned) == [false, false, true])
  #expect(marks.spoken("Claude", now: marksNow, calendar: utc, balances: true).contains(
    ". Saldos: Conta a-100 100% em 5 horas (semana não informada), Conta a-100b 100% em 5 horas (semana não informada), Conta a-9 9% em 5 horas (semana não informada), Conta b-64 64% na semana (5 horas não informada). Prazos: "))
  #expect(!marks.spoken("Claude", now: marksNow, calendar: utc).contains("Saldos"))
}

@Test func aWaitIsTheEndOfTheLastKnownBlockerNeverTheWindowsLength() {
  // A Max 5x that reports no weekly window says so.
  let alone = SubscriptionMarks(accounts: [markAccount("alone", plan: "max5x", fiveHour: 0,
    fiveHourResetAt: "2026-11-01T12:10:00Z", capacity: false)], now: marksNow)
  #expect(alone.groups[0].accounts[0].wait!.spoken(now: marksNow, calendar: utc)
    == "volta às 12:10, em 30 min (previsto pela janela de 5 horas; semana não informada)")
  let marks = SubscriptionMarks(accounts: [
    // The proxy's 35-minute wait alone.
    markAccount("proxy", plan: "max5x", weekly: 60, fiveHour: 40, capacity: false, cooldown: 35 * 60),
    // A 5-hour window at zero that renews in 1 h 40: "2h", not the window's 5 hours.
    markAccount("window", plan: "max5x", weekly: 60, fiveHour: 0, fiveHourResetAt: "2026-11-01T13:20:00Z", capacity: false),
    // The window is back in 50 minutes but the proxy waits 2 hours: the later one.
    markAccount("both", plan: "max5x", weekly: 60, fiveHour: 0, fiveHourResetAt: "2026-11-01T12:30:00Z", capacity: false,
                cooldown: 2 * 3_600),
    // The week renews in 1 day and 22 hours.
    markAccount("week", plan: "max20x", weekly: 0, capacity: false, resetAt: "2026-11-03T09:40:00Z"),
    // An exhausted week whose 5-hour window renews later still: back only when both are.
    markAccount("week-late", plan: "max20x", weekly: 0, fiveHour: 0, fiveHourResetAt: "2026-11-03T12:00:00Z",
                capacity: false, resetAt: "2026-11-03T09:40:00Z"),
  ], now: marksNow)
  let waits = Dictionary(uniqueKeysWithValues: marks.groups.flatMap(\.accounts).map { ($0.id, $0.wait) })
  #expect(waits["proxy"]!!.short(now: marksNow) == "35m" && waits["proxy"]!!.causes == [.proxy])
  #expect(waits["window"]!!.short(now: marksNow) == "2h" && waits["window"]!!.causes == [.fiveHour])
  #expect(waits["both"]!!.until == Subscriptions.date("2026-11-01T13:40:00Z") && waits["both"]!!.causes == [.proxy, .fiveHour])
  #expect(waits["week"]!!.short(now: marksNow) == "2d" && waits["week"]!!.causes == [.weekly])
  #expect(waits["week-late"]!!.until == Subscriptions.date("2026-11-03T12:00:00Z")
    && waits["week-late"]!!.causes == [.fiveHour, .weekly])
  #expect(marks.groups[1].accounts.map(\.mark) == [.exhausted, .exhausted])
  // The strip's order is unchanged: stopped by release, then exhausted.
  #expect(marks.runs.map { $0.accounts.map(\.id) } == [["proxy", "window", "both"], ["week", "week-late"]])
  #expect(waits["window"]!!.spoken(now: marksNow, calendar: utc)
    == "volta às 13:20, em 1 h 40 min (previsto pela janela de 5 horas)")
  #expect(waits["both"]!!.spoken(now: marksNow, calendar: utc)
    == "volta às 13:40, em 2 h (previsto pela espera do proxy e janela de 5 horas)")
  #expect(waits["week"]!!.spoken(now: marksNow, calendar: utc)
    == "volta ter 03/11 09:40, em 1 dia e 22 h (previsto pela renovação da semana)")
  #expect(marks.next == .init(count: 1, at: Subscriptions.date("2026-11-01T12:15:00Z")!))
  #expect(marks.summary(now: marksNow, next: true) == "0 prontas · +1 em 35m")
  #expect(marks.summary(now: marksNow, next: true, compact: true) == "0 prontas · +1 35m")
  #expect(marks.summary(now: marksNow, next: false) == "0 prontas")
  #expect(marks.spoken("Claude", now: marksNow, calendar: utc, balances: true).hasSuffix(
    "; Conta week-late volta ter 03/11 12:00, em 2 dias (previsto pela janela de 5 horas e renovação da semana)"))
}

@Test func anUnknownOrPassedTimeOrAnOldMeasurementShowsNoCountdown() {
  var stale = markAccount("stale", plan: "max5x", weekly: 60, fiveHour: 0, fiveHourResetAt: "2026-11-01T13:00:00Z",
                          capacity: false, cooldown: 600)
  stale.stale = true
  let marks = SubscriptionMarks(accounts: [
    // Refused without a known blocker.
    markAccount("why", plan: "max5x", weekly: 60, fiveHour: 30, capacity: false),
    // A blocker without its end.
    markAccount("no-end", plan: "max5x", weekly: 60, fiveHour: 0, capacity: false),
    // The 5-hour reset passed after the reading: unmeasured until the proxy reads it again.
    markAccount("passed", plan: "max5x", weekly: 60, fiveHour: 0, fiveHourResetAt: "2026-11-01T11:38:00Z", capacity: false),
    // An exhausted week with no renewal reported.
    markAccount("week", plan: "max20x", weekly: 0, capacity: false, resetAt: nil),
    stale,
    markAccount("login", plan: "max20x", weekly: 0, capacity: false, authenticated: false),
    markAccount("free", plan: "free"),
    markAccount("ready", plan: "max5x", weekly: 60, fiveHour: 60),
  ], now: marksNow)
  let accounts = Dictionary(uniqueKeysWithValues: marks.groups.flatMap(\.accounts).map { ($0.id, $0) })
  #expect(accounts.values.filter { $0.wait != nil }.isEmpty)
  #expect(accounts["why"]!.mark == .blocked(until: nil) && accounts["no-end"]!.mark == .blocked(until: nil))
  #expect(accounts["passed"]!.mark == .unmeasured && accounts["week"]!.mark == .exhausted)
  // The details still read the proxy's wait; the strip counts nothing down over old windows.
  #expect(accounts["stale"]!.mark == .blocked(until: marksNow.addingTimeInterval(600)))
  #expect(accounts["login"]!.mark == .attention && accounts["free"]!.mark == .unmeasured)
  #expect(marks.next == nil && marks.summary(now: marksNow, next: true) == "1 pronta")
  #expect(!marks.spoken("Claude", now: marksNow, calendar: utc, balances: true).contains("Prazos"))
}

@Test func theCountdownRoundsUpSoItNeverPromisesTheAccountSooner() {
  func short(_ seconds: Double) -> String {
    SubscriptionMarks.Wait(until: marksNow.addingTimeInterval(seconds), causes: [.proxy]).short(now: marksNow)
  }
  #expect(short(20) == "1m" && short(60) == "1m" && short(61) == "2m" && short(59 * 60) == "59m")
  #expect(short(59 * 60 + 1) == "1h" && short(3_600) == "1h" && short(3_601) == "2h" && short(100 * 60) == "2h")
  #expect(short(23 * 3_600 + 1) == "1d" && short(86_400) == "1d" && short(86_401) == "2d" && short(46 * 3_600) == "2d")
}
