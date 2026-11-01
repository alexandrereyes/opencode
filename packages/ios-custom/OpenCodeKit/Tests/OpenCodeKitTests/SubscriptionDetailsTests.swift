import Foundation
import Testing

@testable import OpenCodeKit

private let detailsNow = Subscriptions.date("2026-11-01T12:35:00Z")!
private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar
}()

private func detailAccount(_ id: String, plan: String?, weekly: Double? = nil, resetAt: String? = nil,
                           fiveHour: Double? = nil, fiveHourResetAt: String? = nil, capacity: Bool? = true,
                           cooldown: Double = 0, stale: Bool = false, enabled: Bool = true,
                           observedAt: String? = "2026-11-01T12:31:00Z", credits: Double? = nil,
                           resets: Subscriptions.BankedResets? = nil) -> Subscriptions.Account {
  .init(id: id, name: id.capitalized, enabled: enabled, plan: plan, remaining: weekly, resetAt: resetAt,
        fiveHourRemaining: fiveHour, fiveHourResetAt: fiveHourResetAt, observedAt: observedAt, stale: stale,
        hasCapacity: capacity, cooldownSeconds: cooldown, credits: credits, bankedResets: resets)
}

private let codex = [
  detailAccount("principal", plan: "promax", weekly: 78, resetAt: "2026-11-07T23:21:00Z", fiveHour: 64,
                fiveHourResetAt: "2026-11-01T16:10:00Z", credits: 21_877, resets: .init(available: 0)),
  detailAccount("kauri", plan: "prolite", weekly: 41, resetAt: "2026-11-05T11:00:00Z", fiveHour: 0,
                fiveHourResetAt: "2026-11-01T14:15:00Z", capacity: false,
                resets: .init(available: 1, earliestExpiresAt: "2026-11-06T12:00:00Z")),
  detailAccount("ponto", plan: "prolite", weekly: 0, resetAt: "2026-11-03T11:53:00Z", fiveHour: 30,
                fiveHourResetAt: "2026-11-01T15:00:00Z", capacity: false, resets: .init(available: 0)),
  detailAccount("teste-a", plan: "free", capacity: nil, observedAt: nil),
  detailAccount("teste-b", plan: "free", capacity: nil, observedAt: nil),
]

@Test func detailsListEveryPlanInTheStripOrderWithOneWindowPerAccount() {
  let details = SubscriptionDetails(accounts: codex, pinned: "principal", now: detailsNow)
  #expect(details.groups.map(\.title) == ["Pro Max", "Pro 5x", "Free"])
  #expect(details.groups.map(\.ready) == [1, 0, 0])
  #expect(details.marks.ready == 1 && details.marks.total == 5)
  let principal = details.groups[0].accounts[0]
  #expect(principal.mark == .ready && principal.pinned)
  #expect(principal.fiveHour == .init(remaining: 64, resetAt: Subscriptions.date("2026-11-01T16:10:00Z"), blocking: false))
  #expect(principal.weekly == .init(remaining: 78, resetAt: Subscriptions.date("2026-11-07T23:21:00Z"), blocking: false))
  let kauri = details.groups[1].accounts[0]
  #expect(kauri.cause == .fiveHour && kauri.fiveHour?.blocking == true && kauri.weekly?.remaining == 41)
  // The week of an exhausted account blocks it; its 5-hour window is no longer shown.
  let ponto = details.groups[1].accounts[1]
  #expect(ponto.mark == .exhausted && ponto.fiveHour == nil && ponto.weekly?.blocking == true)
  // Free accounts are not measured: no window, never 0%, and nothing but their name and state to show.
  #expect(details.groups[2].unmeasured)
  #expect(details.groups[2].accounts.allSatisfy { $0.mark == .unmeasured && $0.weekly == nil && $0.compact })
}

@Test func detailsSeparateTheNextReleaseFromTheNextWeeklyRenewal() {
  let details = SubscriptionDetails(accounts: codex, now: detailsNow)
  #expect(details.release == .init(at: Subscriptions.date("2026-11-01T14:15:00Z")!, names: ["Kauri"], cause: .fiveHour))
  #expect(details.stoppedWithoutTime == 0)
  // Ponto's renewal comes first, before Kauri's and Principal's; it is a renewal, not a release.
  #expect(details.renewal == .init(at: Subscriptions.date("2026-11-03T11:53:00Z")!, names: ["Ponto"]))
  #expect(details.observedAt == Subscriptions.date("2026-11-01T12:31:00Z"))
  #expect(details.resets == .init(available: 1, accounts: 3, unknown: 2, earliest: Subscriptions.date("2026-11-06T12:00:00Z")))
  #expect(SubscriptionFormat.moment(details.release!.at, now: detailsNow, calendar: utc) == "14:15")
  #expect(SubscriptionFormat.moment(details.renewal!.at, now: detailsNow, calendar: utc) == "ter 03/11 11:53")
}

@Test func detailsKeepUnknownsUnknownAndListDisabledAccounts() {
  let details = SubscriptionDetails(accounts: [
    // A proxy wait without a known end, and a refusal the windows do not explain.
    detailAccount("espera", plan: "max5x", fiveHour: 0, capacity: false, cooldown: 600),
    detailAccount("recusa", plan: "max5x", fiveHour: 40, fiveHourResetAt: "2026-11-01T15:00:00Z", capacity: false),
    // A stale measurement shows no percent, not the old one or zero.
    detailAccount("velha", plan: "max5x", weekly: 55, resetAt: "2026-11-05T11:00:00Z", stale: true),
    detailAccount("pausada", plan: "max20x", weekly: 90, resetAt: "2026-11-05T11:00:00Z", enabled: false),
    detailAccount("sobra", plan: "plus", weekly: 90, enabled: false),
  ], now: detailsNow)
  #expect(details.groups.map(\.title) == ["Max 5x", "Max 20x", "Plus"])
  let max5x = details.groups[0]
  #expect(max5x.accounts.map(\.cause) == [.wait, .unexplained, nil])
  #expect(max5x.accounts[2].mark == .unmeasured && max5x.accounts[2].weekly?.remaining == nil)
  #expect(max5x.accounts[2].weekly?.resetAt == Subscriptions.date("2026-11-05T11:00:00Z"))
  #expect(details.release == nil && details.stoppedWithoutTime == 2)
  // Disabled accounts are listed (the strip leaves them out) but never counted.
  #expect(details.marks.total == 3)
  #expect(details.groups[1...].allSatisfy { $0.accounts.map(\.mark) == [nil] && $0.disabled == 1 && $0.ready == 0 })
}

@Test func detailsAddDisabledAccountsToTheirPlanAfterTheEnabledOnes() {
  let details = SubscriptionDetails(accounts: [
    detailAccount("pausada", plan: "promax", weekly: 90, enabled: false),
    detailAccount("ativa", plan: "promax", weekly: 70, resetAt: "2026-11-05T11:00:00Z"),
  ], now: detailsNow)
  #expect(details.groups.count == 1)
  #expect(details.groups[0].accounts.map(\.name) == ["Ativa", "Pausada"])
  #expect(details.groups[0].ready == 1 && details.groups[0].enabled.count == 1)
  #expect(SubscriptionFormat.age(Subscriptions.date("2026-11-01T12:31:00Z")!, now: detailsNow) == "Medição mais antiga há 4 min")
}
