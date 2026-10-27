import Foundation
import Testing

@testable import OpenCodeKit

private let tableNow = Subscriptions.date("2026-10-27T12:00:00Z")!

private func tableAccount(_ id: String, _ name: String, plan: String? = "pro", weekly: Double? = 50,
                          fiveHour: Double? = 50, capacity: Bool? = true, resets: Double? = 0,
                          resetAt: String = "2026-10-30T09:00:00Z") -> Subscriptions.Account {
  .init(id: id, name: name, plan: plan, remaining: weekly, resetAt: resetAt, fiveHourRemaining: fiveHour,
        fiveHourResetAt: "2026-10-27T14:00:00Z", observedAt: "2026-10-27T11:50:00Z", hasCapacity: capacity,
        bankedResets: resets.map { .init(available: $0) })
}

private actor TableClient: SubscriptionClient {
  let value: Subscriptions
  init(_ value: Subscriptions) { self.value = value }
  func subscriptions() async throws -> Subscriptions { value }
  func setSubscriptionAutomation(_ provider: SubscriptionProvider, enabled: Bool) async throws -> Subscriptions.Automation {
    .init(enabled: enabled)
  }
  func consumeSubscriptionReset(_ provider: SubscriptionProvider, accountID: String) async throws -> SubscriptionResetResult {
    .init(code: "ok", windowsReset: 1)
  }
}

@Test func subscriptionGroupsKeepTheSheetOrderAndOpenOtherPlansOnce() {
  let accounts = SubscriptionProjection.sorted([
    tableAccount("plus", "Conta Plus", plan: "plus"),
    tableAccount("empty", "Conta sem cota", weekly: 0, capacity: false),
    tableAccount("max", "Conta Max", plan: "promax"),
    tableAccount("test", "Conta de teste"),
    tableAccount("lite", "Conta Lite", plan: "prolite"),
  ], now: tableNow)
  let groups = SubscriptionGroup.groups(accounts, provider: .codex, now: tableNow)
  #expect(groups.map(\.plan) == ["promax", "pro", "prolite", "plus"])
  #expect(groups.map(\.opensOthers) == [false, false, true, false])
  #expect(groups[1].rows.map(\.id) == ["test", "empty"])
  #expect(groups[1].rows.map(\.order) == [1, 2])
  #expect(groups[1].projection.ready == 1 && groups[1].count == 2)
}

@Test func subscriptionSearchFiltersByAccountNameIgnoringCaseAndAccents() {
  let accounts = [tableAccount("a", "Conta Reserva"), tableAccount("b", "Conta trabalho"),
                  tableAccount("c", "Estúdio", plan: "plus")]
  #expect(SubscriptionAccountRow.matches(accounts[0], query: "  reser "))
  #expect(SubscriptionAccountRow.matches(accounts[2], query: "ESTUDIO"))
  #expect(!SubscriptionAccountRow.matches(accounts[1], query: "pro"))
  #expect(SubscriptionAccountRow.matches(accounts[1], query: ""))
  let groups = SubscriptionGroup.groups(accounts, provider: .codex, now: tableNow, query: "estú")
  // The pool group has no match and is left out, so "Outros planos" moves to the first visible group.
  #expect(groups.map(\.plan) == ["plus"] && groups[0].opensOthers)
  let pool = SubscriptionGroup.groups(accounts, provider: .codex, now: tableNow, query: "trab")
  // The heading still counts the whole group, not just the match.
  #expect(pool.map(\.rows.count) == [1] && pool[0].count == 2)
  #expect(SubscriptionGroup.groups(accounts, provider: .codex, now: tableNow, query: "nada").isEmpty)
}

@Test func subscriptionTableFocusPrefersClickedThenSummaryThenFirstVisible() {
  let accounts = [tableAccount("a", "Conta A"), tableAccount("b", "Conta B"), tableAccount("c", "Conta C")]
  let all = SubscriptionGroup.groups(accounts, provider: .codex, now: tableNow)
  #expect(SubscriptionGroup.focus("c", summary: "b", in: all) == "c")
  #expect(SubscriptionGroup.focus(nil, summary: "b", in: all) == "b")
  #expect(SubscriptionGroup.focus("gone", summary: nil, in: all) == "a")
  let filtered = SubscriptionGroup.groups(accounts, provider: .codex, now: tableNow, query: "a C")
  #expect(SubscriptionGroup.focus("a", summary: "b", in: filtered) == "c")
  #expect(SubscriptionGroup.focus("a", summary: "b", in: []) == nil)
}

@Test func subscriptionRowsShowTheCardValuesAndSortByEveryColumn() {
  var stale = tableAccount("stale", "Desatualizada", weekly: 70, fiveHour: 20, resets: nil)
  stale.stale = true
  var off = tableAccount("off", "Desligada", weekly: 90, resets: 1)
  off.enabled = false
  let accounts = [
    tableAccount("empty", "Sem cota", weekly: 0, fiveHour: 40, capacity: false, resetAt: "2026-10-28T09:00:00Z"),
    tableAccount("five", "Cinco horas", weekly: 30, fiveHour: 0, capacity: false, resets: 2),
    tableAccount("ok", "Disponível", weekly: 80, fiveHour: 70, resets: 3, resetAt: "2026-10-29T09:00:00Z"),
    stale, off,
  ]
  let rows = accounts.enumerated().map { SubscriptionAccountRow($0.element, order: $0.offset, now: tableNow) }
  // An exhausted week hides the 5-hour window, as on the iPhone card; stale values are unknown.
  #expect(rows[0].fiveHour == nil && rows[0].weekly == 0 && rows[0].state == .weeklyExhausted)
  #expect(rows[1].state == .fiveHourExhausted && rows[1].canReset)
  #expect(rows[3].weekly == nil && rows[3].fiveHour == nil && rows[3].state == .unconfirmed && rows[3].resets == nil)
  #expect(rows[4].state == .disabled)
  #expect(rows[2].renewalLabel == SubscriptionFormat.date(Subscriptions.date("2026-10-29T09:00:00Z")).replacingOccurrences(of: " às ", with: "\n"))
  #expect(rows[2].renewalLabel.contains("\n") && !rows[2].renewalLabel.contains("às"))
  #expect(rows.sorted(using: KeyPathComparator(\.order)).map(\.id) == ["empty", "five", "ok", "stale", "off"])
  #expect(rows.sorted(using: KeyPathComparator(\.name)).map(\.id) == ["five", "stale", "off", "ok", "empty"])
  #expect(rows.sorted(using: KeyPathComparator(\.weeklyKey, order: .reverse)).map(\.id) == ["off", "ok", "five", "empty", "stale"])
  let byFiveHour = rows.sorted(using: KeyPathComparator(\.fiveHourKey)).map(\.id)
  #expect(Set(byFiveHour.prefix(2)) == ["empty", "stale"] && byFiveHour[2] == "five")
  #expect(rows.sorted(using: KeyPathComparator(\.renewalKey)).first?.id == "empty")
  #expect(rows.sorted(using: KeyPathComparator(\.statusKey)).map(\.id).first == "ok")
  #expect(rows.sorted(using: KeyPathComparator(\.statusKey)).map(\.id).last == "off")
  #expect(rows.sorted(using: KeyPathComparator(\.resetsKey, order: .reverse)).map(\.id).prefix(2) == ["ok", "five"])
}

@MainActor @Test func subscriptionSidebarListsOfferedProvidersThenResetsAndFollowsTheSummary() async {
  let suite = "proxy-sidebar-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let codex = [tableAccount("a", "Conta A", weekly: 80), tableAccount("b", "Conta B", weekly: 20, capacity: false)]
  let value = Subscriptions(status: "ok", accounts: codex, automation: .init(enabled: false),
    anthropic: .init(status: "ok", accounts: [tableAccount("c", "Claude", plan: "max20x", weekly: 61)]))
  let store = SubscriptionStore(server: "test", client: TableClient(value), defaults: defaults,
    clock: .init(now: { tableNow }, sleep: { _ in }))
  #expect(store.sidebar.map(\.pane) == [.provider(.codex), .provider(.anthropic), .resets])
  #expect(store.sidebar[0].remaining == nil)
  await store.refresh()
  #expect(store.sidebar.map(\.title) == ["Codex", "Claude", "Redefinições"])
  #expect(store.sidebar[0].remaining == 50 && store.sidebar[0].ready)
  #expect(store.sidebar[1].remaining == 61)
  store.toggleSelection(codex[1], provider: .codex)
  #expect(store.sidebar[0].remaining == 20 && !store.sidebar[0].ready)
  #expect(store.pane(.provider(.anthropic)) == .provider(.anthropic))

  let codexOnly = SubscriptionStore(server: "other", client: TableClient(.init(status: "ok", accounts: codex)),
    defaults: defaults, clock: .init(now: { tableNow }, sleep: { _ in }))
  await codexOnly.refresh()
  #expect(codexOnly.sidebar.map(\.pane) == [.provider(.codex), .resets])
  #expect(codexOnly.pane(.provider(.anthropic)) == .provider(.codex))
  #expect(codexOnly.pane(.resets) == .resets)
}

@Test func subscriptionConfirmationTextsAndFreshness() {
  let account = tableAccount("a", "Conta A")
  #expect(SubscriptionStore.Confirmation.reset(.codex, account).title == "Consumir uma redefinição?")
  #expect(SubscriptionStore.Confirmation.reset(.codex, account).action == "Consumir redefinição")
  #expect(SubscriptionStore.Confirmation.reset(.codex, account).message.contains("Conta A"))
  #expect(SubscriptionStore.Confirmation.automation(.anthropic, true).title == "Ativar redefinição automática?")
  #expect(SubscriptionStore.Confirmation.automation(.anthropic, false).action == "Pausar")
  #expect(SubscriptionStore.Confirmation.automation(.anthropic, true).message.contains("Claude"))
  let pool = SubscriptionProjection(accounts: [account], plan: "pro", now: tableNow)
  #expect(pool.freshness(now: tableNow) == "Medição mais antiga · há 10 min")
  #expect(pool.freshness(now: Subscriptions.date("2026-10-27T11:50:30Z")!) == "Atualizado agora")
  var stale = account; stale.stale = true
  #expect(SubscriptionProjection(accounts: [stale], plan: "pro", now: tableNow).freshness(now: tableNow) == "0 de 1 medições confirmadas")
}
