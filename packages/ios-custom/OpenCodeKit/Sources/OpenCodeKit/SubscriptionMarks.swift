import Foundation

/// One subscription in the Sessões quota strip. Availability reported by the proxy (`hasCapacity`) and a measured
/// balance are separate facts: an account the proxy accepts but whose windows were never measured is `unmeasured`,
/// not ready, and an unknown window is never read as zero.
public enum SubscriptionMark: Sendable, Equatable {
  /// Enabled, authenticated, without a wait, measured recently and accepted by the proxy now.
  case ready
  /// Not usable now for a reason that passes: the proxy's wait, the 5-hour window at zero, or a refusal the data
  /// does not explain. `until` is set only when every known blocker reports when it ends.
  case blocked(until: Date?)
  /// The weekly window measured at zero and the proxy refusing: back only at the weekly renewal.
  case exhausted
  /// No fresh measurement (none yet, stale, a renewal passed since, or no window reported at all).
  case unmeasured
  /// Needs the owner: the proxy lost its authentication.
  case attention

  public init(_ account: Subscriptions.Account, now: Date) {
    let fresh = !account.stale && account.hasCapacity != nil && !account.renewalPassed(at: now)
      && (account.remaining != nil || account.fiveHourRemaining != nil)
    if !account.authenticated { self = .attention; return }
    if fresh, account.hasCapacity == false, account.remaining == 0 { self = .exhausted; return }
    if account.cooldownSeconds > 0 { self = .blocked(until: Self.release(account, fresh: fresh, now: now)); return }
    if !fresh { self = .unmeasured; return }
    // The proxy's permission wins over a rounded percent: "0%" with capacity still serves.
    if account.hasCapacity == true { self = .ready; return }
    self = .blocked(until: Self.release(account, fresh: fresh, now: now))
  }

  /// When every known blocker ends. A refusal with no known blocker, or a blocker without an end, has no time:
  /// the weekly renewal is not a release for an account the weekly window does not block.
  static func release(_ account: Subscriptions.Account, fresh: Bool, now: Date) -> Date? {
    var ends: [Date?] = []
    if account.cooldownSeconds > 0 { ends.append(now.addingTimeInterval(account.cooldownSeconds)) }
    if fresh, account.fiveHourRemaining == 0 { ends.append(Subscriptions.date(account.fiveHourResetAt)) }
    guard !ends.isEmpty, !ends.contains(where: { $0 == nil }) else { return nil }
    return ends.compactMap { $0 }.max().flatMap { $0 > now ? $0 : nil }
  }

  public var title: String {
    switch self {
    case .ready: "pronta"
    case .blocked: "parada"
    case .exhausted: "semana esgotada"
    case .unmeasured: "sem medição"
    case .attention: "precisa de login"
    }
  }
}

/// A provider's subscriptions for the Sessões strip: every enabled account of every plan, grouped by the plan the
/// proxy reports, one mark per account. No percent is summed or averaged and plans carry no weight: a group label
/// only identifies the plan. Disabled accounts stay out (the proxy does not use them); details still list them.
public struct SubscriptionMarks: Sendable {
  public struct Account: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let mark: SubscriptionMark
    /// The "Mostrar no resumo" account: highlighted, never the only one shown.
    public let pinned: Bool
    /// What a ready account has left; nil for every other mark, which never shows a number.
    public let balance: Balance?
  }
  /// The share left of the window that limits a ready account now: the smaller of its measured 5-hour and weekly
  /// windows, never a capacity and never comparable across plans. With one window reported, it is that one and
  /// `alone` says the other is unknown.
  public struct Balance: Sendable, Equatable {
    public enum Window: Sendable, Equatable { case fiveHour, weekly }
    public let percent: Int
    public let window: Window
    public let alone: Bool

    init(percent: Int, window: Window, alone: Bool) {
      self.percent = percent
      self.window = window
      self.alone = alone
    }

    init?(_ account: Subscriptions.Account) {
      let windows = [(Window.fiveHour, account.fiveHourRemaining), (.weekly, account.remaining)]
        .compactMap { window, value in value.map { (window, $0) } }
      guard let lowest = windows.min(by: { $0.1 < $1.1 }) else { return nil }
      percent = Int(min(100, max(0, lowest.1)).rounded())
      window = lowest.0
      alone = windows.count == 1
    }

    /// `72% na semana`, `100% em 5 horas (semana não informada)`.
    public var spoken: String {
      let place = window == .weekly ? "na semana" : "em 5 horas"
      let missing = window == .weekly ? "5 horas não informada" : "semana não informada"
      return "\(percent)% \(place)" + (alone ? " (\(missing))" : "")
    }
  }
  public struct Group: Sendable, Identifiable {
    public let plan: String?
    /// The plan's multiplier when its label has one (`5x`, `20x`), else the label itself (`Pro Max`, `Free`).
    public let label: String
    /// The full plan name for VoiceOver.
    public let title: String
    public let accounts: [Account]
    /// The plan for `groups`; the run's position too for `runs`, where a plan may come back.
    var key: String? = nil
    public var id: String { key ?? plan ?? "" }
    public var ready: Int { accounts.filter { $0.mark == .ready }.count }
    public func count(_ kind: Kind) -> Int { accounts.filter { Kind($0.mark) == kind }.count }
    /// No account measured: shown apart, as a count of `?`.
    public var unmeasured: Bool { count(.unmeasured) == accounts.count }
  }
  /// The mark without its release time, for counting.
  public enum Kind: Sendable, CaseIterable { case ready, blocked, exhausted, unmeasured, attention
    public init(_ mark: SubscriptionMark) {
      switch mark {
      case .ready: self = .ready
      case .blocked: self = .blocked
      case .exhausted: self = .exhausted
      case .unmeasured: self = .unmeasured
      case .attention: self = .attention
      }
    }
  }
  public struct Release: Sendable, Equatable {
    public let count: Int
    public let at: Date
  }

  /// Groups in the proxy's order; groups with no measured account (such as Free accounts the proxy accepts but
  /// does not measure) go last, apart.
  public let groups: [Group]
  /// The strip's order: ready accounts first (plans in the proxy's order, the larger balance first, then the proxy's
  /// order), then stopped ones by their release (unknown last), exhausted, needing login and unmeasured (each by plan,
  /// then the proxy's order). Consecutive accounts of one plan form a run, so a plan's label comes back when the
  /// states split it. Balances order accounts only within one plan.
  public let runs: [Group]
  /// Ready subscriptions: a count of accounts, not of quota.
  public var ready: Int { groups.reduce(0) { $0 + $1.ready } }
  public var total: Int { groups.reduce(0) { $0 + $1.accounts.count } }
  public func count(_ kind: Kind) -> Int { groups.reduce(0) { $0 + $1.count(kind) } }
  /// The earliest time a blocked account is back, and how many come back within that minute.
  public let release: Release?

  public init(accounts: [Subscriptions.Account], pinned: String? = nil, now: Date) {
    let enabled = accounts.filter(\.enabled)
    let plans = enabled.reduce(into: [String?]()) { if !$0.contains($1.plan) { $0.append($1.plan) } }
    let built = plans.map { plan in
      // A plan the app has no name for keeps the proxy's own identifier, capitalized.
      let title = plan.map { Self.capitalized(Subscriptions.planLabel($0)) } ?? "Plano desconhecido"
      return Group(plan: plan, label: plan == nil ? "Outro" : Self.label(title), title: title,
        accounts: enabled.filter { $0.plan == plan }.map { account in
          let mark = SubscriptionMark(account, now: now)
          return Account(id: account.id, name: account.name, mark: mark, pinned: account.id == pinned,
            balance: mark == .ready ? Balance(account) : nil)
        })
    }
    let ordered = built.filter { $0.count(.unmeasured) < $0.accounts.count }
      + built.filter { $0.count(.unmeasured) == $0.accounts.count }
    groups = ordered
    runs = Self.runs(built, order: enabled.map(\.id))
    let releases = ordered.flatMap(\.accounts).compactMap { account -> Date? in
      if case .blocked(let until) = account.mark { return until }
      return nil
    }
    release = releases.min().map { first in
      Release(count: releases.filter { $0.timeIntervalSince(first) < 60 }.count, at: first)
    }
  }

  static func runs(_ groups: [Group], order: [String]) -> [Group] {
    let position = Dictionary(order.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { first, _ in first })
    let entries = groups.enumerated().flatMap { plan, group in
      group.accounts.map { account in (group: group, account: account, key: Self.key(account, plan: Double(plan),
        position: position[account.id] ?? 0)) }
    }
    let sorted = entries.sorted { $0.key.lexicographicallyPrecedes($1.key) }
    return sorted.reduce(into: [Group]()) { runs, entry in
      if let last = runs.last, last.plan == entry.group.plan {
        runs[runs.count - 1] = Group(plan: last.plan, label: last.label, title: last.title,
          accounts: last.accounts + [entry.account], key: last.key)
        return
      }
      runs.append(Group(plan: entry.group.plan, label: entry.group.label, title: entry.group.title,
        accounts: [entry.account], key: "\(runs.count):\(entry.group.plan ?? "")"))
    }
  }

  /// State first; then what orders that state; the proxy's order last, so ties never swap between reads.
  static func key(_ account: Account, plan: Double, position: Double) -> [Double] {
    switch account.mark {
    case .ready: [0, plan, -Double(account.balance?.percent ?? 0), position]
    case .blocked(let until): [1, until?.timeIntervalSince1970 ?? .greatestFiniteMagnitude, plan, position]
    case .exhausted: [2, plan, position, 0]
    case .attention: [3, plan, position, 0]
    case .unmeasured: [4, plan, position, 0]
    }
  }

  static func label(_ title: String) -> String {
    let multiplier = title.split(separator: " ").first { $0.count > 1 && $0.hasSuffix("x") && $0.dropLast().allSatisfy(\.isNumber) }
    return multiplier.map(String.init) ?? title
  }

  static func capitalized(_ title: String) -> String { title.prefix(1).uppercased() + title.dropFirst() }

  /// `+1 às 10:30` (`+1 10:30` when compact), or with the date when it is not today.
  public func releaseLabel(now: Date, calendar: Calendar = .current, compact: Bool = false) -> String? {
    guard let release else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = calendar.isDate(release.at, inSameDayAs: now) ? compact ? "HH:mm" : "'às' HH:mm" : "dd/MM HH:mm"
    return "+\(release.count) \(formatter.string(from: release.at))"
  }

  /// `4 prontas · +1 às 10:30`; with nothing ready, what the provider has instead. `release: false` leaves the
  /// release out for the narrowest strip.
  public func summary(now: Date, calendar: Calendar = .current, compact: Bool = false, release: Bool = true) -> String {
    let readyText = ready == 1 ? "1 pronta" : "\(ready) prontas"
    if total == 0 { return "nenhuma conta" }
    if ready == 0, groups.allSatisfy({ $0.count(.unmeasured) == $0.accounts.count }) { return "sem medição" }
    return [readyText, release ? releaseLabel(now: now, calendar: calendar, compact: compact) : nil].compactMap { $0 }
      .joined(separator: " · ")
  }

  /// VoiceOver: every plan with its accounts by state, then the release; `balances` adds each ready account's
  /// balance and its window, in the strip's order.
  public func spoken(_ provider: String, now: Date, calendar: Calendar = .current, balances: Bool = false) -> String {
    let plans = groups.map { group in
      let parts = Kind.allCases.compactMap { kind -> String? in
        let count = group.count(kind)
        guard count > 0 else { return nil }
        switch kind {
        case .ready: return count == 1 ? "1 pronta" : "\(count) prontas"
        case .blocked: return count == 1 ? "1 parada" : "\(count) paradas"
        case .exhausted: return count == 1 ? "1 com a semana esgotada" : "\(count) com a semana esgotada"
        case .unmeasured: return "\(count) sem medição"
        case .attention: return count == 1 ? "1 precisa de login" : "\(count) precisam de login"
        }
      }
      return "\(group.title): " + parts.joined(separator: ", ")
    }
    let release = releaseLabel(now: now, calendar: calendar).map { ". " + $0.replacingOccurrences(of: "+", with: "Mais ") + " volta" } ?? ""
    let left = runs.flatMap(\.accounts).compactMap { account in account.balance.map { account.name + " " + $0.spoken } }
    let tail = balances && !left.isEmpty ? ". Saldos: " + left.joined(separator: ", ") : ""
    return "\(provider), \(ready) de \(total) assinaturas prontas agora. " + plans.joined(separator: ". ") + release + tail
  }
}

extension SubscriptionStore {
  /// The Sessões strip of a provider; nil until the proxy answers, or when its pool is not readable.
  public func marks(_ provider: SubscriptionProvider) -> SubscriptionMarks? {
    guard let snapshot, snapshot.pool(provider).status == "ok" else { return nil }
    return SubscriptionMarks(accounts: snapshot.pool(provider).accounts, pinned: selectedIDs[provider], now: now)
  }
}
