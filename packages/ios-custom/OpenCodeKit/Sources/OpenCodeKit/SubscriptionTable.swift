import Foundation

/// The Mac LLM proxy window's sidebar: one entry per provider the server offers, then Redefinições.
public enum SubscriptionPane: Hashable, Sendable {
  case provider(SubscriptionProvider)
  case resets
}

public struct SubscriptionSidebarRow: Identifiable, Sendable {
  public let pane: SubscriptionPane
  public let title: String
  /// What the provider's Sessões ring shows: the "Mostrar no resumo" account, else the pool; nil when unknown.
  public let remaining: Double?
  public let ready: Bool
  public var id: SubscriptionPane { pane }
}

extension SubscriptionStore {
  public var sidebar: [SubscriptionSidebarRow] {
    providers.map { provider in
      let summary = summary(provider)
      return SubscriptionSidebarRow(pane: .provider(provider), title: provider.title, remaining: summary?.remaining,
        ready: summary?.ready ?? false)
    } + [SubscriptionSidebarRow(pane: .resets, title: "Redefinições", remaining: nil, ready: false)]
  }

  /// The pane to show for a requested one: a provider the server no longer offers falls back to Codex.
  public func pane(_ pane: SubscriptionPane) -> SubscriptionPane {
    if case .provider(let provider) = pane, !providers.contains(provider) { return .provider(.codex) }
    return pane
  }
}

/// One account as a table row. The sort keys are non-optional so `KeyPathComparator` can order the columns;
/// unknown values sort first ascending, and `order` keeps `SubscriptionProjection.sorted`.
public struct SubscriptionAccountRow: Identifiable, Sendable {
  public let account: Subscriptions.Account
  public let order: Int
  public let state: SubscriptionAccountState
  /// The 5-hour window, hidden like on the iPhone card once the week is exhausted; nil when unknown.
  public let fiveHour: Double?
  public let weekly: Double?
  public let renewal: Date?
  /// Banked resets; nil when the proxy did not report the inventory.
  public let resets: Double?

  public init(_ account: Subscriptions.Account, order: Int, now: Date) {
    let weekly = account.value(account.remaining, at: now)
    self.account = account
    self.order = order
    state = account.state(at: now)
    self.weekly = weekly
    fiveHour = weekly == 0 ? nil : account.value(account.fiveHourRemaining, at: now)
    renewal = Subscriptions.date(account.resetAt)
    resets = account.bankedResets?.available
  }

  public var id: String { account.id }
  public var name: String { account.name }
  public var plan: String { Subscriptions.planLabel(account.plan) }
  public var canReset: Bool { (resets ?? 0) > 0 }
  /// The weekly renewal on two lines for a narrow column: `sex, 30/10` above `08:53`.
  public var renewalLabel: String { SubscriptionFormat.date(renewal).replacingOccurrences(of: " às ", with: "\n") }
  public var fiveHourKey: Double { fiveHour ?? -1 }
  public var weeklyKey: Double { weekly ?? -1 }
  public var renewalKey: Date { renewal ?? .distantFuture }
  /// Available first, then the states that still let the account recover, disabled last.
  public var statusKey: Int { SubscriptionAccountState.allCases.count - 1 - (SubscriptionAccountState.allCases.firstIndex(of: state) ?? 0) }
  public var resetsKey: Double { resets ?? -1 }

  /// The search keeps accounts whose name contains the query, ignoring case and accents.
  public static func matches(_ account: Subscriptions.Account, query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || account.name.localizedStandardContains(query)
  }
}

/// A plan's accounts, in the iPhone sheet's order: the provider's own pool first, then "Outros planos".
public struct SubscriptionGroup: Identifiable, Sendable {
  public let plan: String?
  /// The whole group, for the `N/M disponíveis` heading, whatever the search hides.
  public let projection: SubscriptionProjection
  public let count: Int
  /// The rows that match the search.
  public let rows: [SubscriptionAccountRow]
  public let outside: Bool
  /// The first visible group outside the pool opens "Outros planos · fora do saldo acima".
  public let opensOthers: Bool
  public var id: String { plan ?? "" }

  /// `accounts` must already be in `SubscriptionProjection.sorted` order. Groups without a matching row are left
  /// out while searching.
  public static func groups(_ accounts: [Subscriptions.Account], provider: SubscriptionProvider, now: Date,
                            query: String = "") -> [Self] {
    let plans = accounts.reduce(into: [String?]()) { if !$0.contains($1.plan) { $0.append($1.plan) } }
    let visible = plans.compactMap { plan -> (String?, [Subscriptions.Account], [SubscriptionAccountRow])? in
      let group = accounts.filter { $0.plan == plan }
      let rows = accounts.enumerated()
        .filter { $0.element.plan == plan && SubscriptionAccountRow.matches($0.element, query: query) }
        .map { SubscriptionAccountRow($0.element, order: $0.offset, now: now) }
      return rows.isEmpty ? nil : (plan, group, rows)
    }
    return visible.enumerated().map { index, value in
      let outside = !SubscriptionProjection.includes(value.0, in: provider.plan)
      return Self(plan: value.0, projection: SubscriptionProjection(accounts: value.1, plan: value.0 ?? "", now: now),
        count: value.1.count, rows: value.2, outside: outside,
        opensOthers: outside && (index == 0 || SubscriptionProjection.includes(visible[index - 1].0, in: provider.plan)))
    }
  }

  /// The account shown below its table: the one clicked if it is still visible, else the "Mostrar no resumo"
  /// account, else the first row.
  public static func focus(_ current: String?, summary: String?, in groups: [Self]) -> String? {
    let ids = groups.flatMap { $0.rows.map(\.id) }
    if let current, ids.contains(current) { return current }
    if let summary, ids.contains(summary) { return summary }
    return ids.first
  }
}

extension SubscriptionProjection {
  /// How fresh the pool's measurements are, under the iPhone sheet and in the Mac window's footer.
  public func freshness(now: Date) -> String {
    guard let observedAt else { return "\(measured) de \(total) medições confirmadas" }
    let minutes = max(0, Int(now.timeIntervalSince(observedAt) / 60))
    return minutes == 0 ? "Atualizado agora" : "Medição mais antiga · há \(minutes) min"
  }
}

extension SubscriptionStore.Confirmation {
  public var title: String {
    switch self {
    case .automation(_, let enabled): enabled ? "Ativar redefinição automática?" : "Pausar redefinição automática?"
    case .reset: "Consumir uma redefinição?"
    }
  }
  public var action: String {
    switch self {
    case .automation(_, let enabled): enabled ? "Ativar" : "Pausar"
    case .reset: "Consumir redefinição"
    }
  }
  public var message: String {
    switch self {
    case .automation(let provider, let enabled):
      enabled ? "O LLM proxy poderá consumir redefinições guardadas automaticamente para \(provider.title). Isso afeta todo o provedor no servidor."
        : "O LLM proxy deixará de consumir redefinições automaticamente para \(provider.title). Isso afeta todo o provedor no servidor."
    case .reset(_, let account):
      "Uma redefinição guardada de \(account.name) será consumida. A operação pode levar cerca de 90 segundos e não pode ser desfeita."
    }
  }
}
