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
    let fresh = Self.fresh(account, now: now)
    if !account.authenticated { self = .attention; return }
    if fresh, account.hasCapacity == false, account.remaining == 0 { self = .exhausted; return }
    if account.cooldownSeconds > 0 { self = .blocked(until: SubscriptionMarks.Wait(account, now: now)?.until); return }
    if !fresh { self = .unmeasured; return }
    // The proxy's permission wins over a rounded percent: "0%" with capacity still serves.
    if account.hasCapacity == true { self = .ready; return }
    self = .blocked(until: SubscriptionMarks.Wait(account, now: now)?.until)
  }

  /// A measurement the strip can trust now: not stale, with the proxy's answer, no renewal passed since, and at
  /// least one window reported.
  static func fresh(_ account: Subscriptions.Account, now: Date) -> Bool {
    !account.stale && account.hasCapacity != nil && !account.renewalPassed(at: now)
      && (account.remaining != nil || account.fiveHourRemaining != nil)
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
    /// When a stopped or exhausted account is back, when the data says; nil for every other mark and for an
    /// unknown time, which never shows a countdown.
    public let wait: Wait?
  }
  /// When a stopped or exhausted account is back by the data the proxy reports: the end of the last of its known
  /// blockers (the proxy's wait, the 5-hour window at zero, the weekly window at zero), never the first renewal
  /// that would leave another one blocking. Nil when the refusal is unexplained, a blocker has no known end or the
  /// time has already passed (the next reading confirms it). An estimate, not a promise: a limit the proxy does not
  /// report (Max 5x reports no weekly window) can still hold the account.
  public struct Wait: Sendable, Equatable {
    public enum Cause: Sendable, Equatable { case proxy, fiveHour, weekly }
    public let until: Date
    /// Every known blocker, the one that ends last first.
    public let causes: [Cause]
    /// The weekly window is not reported, so it cannot be ruled out.
    public let partial: Bool

    init(until: Date, causes: [Cause], partial: Bool = false) {
      self.until = until
      self.causes = causes
      self.partial = partial
    }

    init?(_ account: Subscriptions.Account, now: Date) {
      let fresh = SubscriptionMark.fresh(account, now: now)
      var blockers: [(cause: Cause, end: Date?)] = []
      if account.cooldownSeconds > 0 { blockers.append((.proxy, now.addingTimeInterval(account.cooldownSeconds))) }
      if fresh, account.fiveHourRemaining == 0 { blockers.append((.fiveHour, Subscriptions.date(account.fiveHourResetAt))) }
      if fresh, account.hasCapacity == false, account.remaining == 0 {
        blockers.append((.weekly, Subscriptions.date(account.resetAt)))
      }
      let ends = blockers.compactMap { blocker in blocker.end.map { (cause: blocker.cause, end: $0) } }
      guard !ends.isEmpty, ends.count == blockers.count, let last = ends.map(\.end).max(), last > now else { return nil }
      until = last
      causes = ends.sorted { $0.end > $1.end }.map(\.cause)
      partial = account.remaining == nil
    }

    /// The strip's countdown, rounded up so it never promises the account sooner: `35m`, `2h`, `2d`.
    public func short(now: Date) -> String {
      let seconds = max(1, until.timeIntervalSince(now))
      let minutes = Int((seconds / 60).rounded(.up))
      if minutes < 60 { return "\(minutes)m" }
      let hours = Int((seconds / 3_600).rounded(.up))
      if hours < 24 { return "\(hours)h" }
      return "\(Int((seconds / 86_400).rounded(.up)))d"
    }

    /// `volta às 16:00, em 1 h 40 min (previsto pela janela de 5 horas e espera do proxy)`.
    public func spoken(now: Date, calendar: Calendar = .current) -> String {
      let total = max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
      let days = total / 1_440
      let hours = total % 1_440 / 60
      let minutes = total % 60
      let span = days > 0
        ? "\(days) \(days == 1 ? "dia" : "dias")" + (hours > 0 ? " e \(hours) h" : "")
        : [hours > 0 ? "\(hours) h" : nil, minutes > 0 ? "\(minutes) min" : nil].compactMap { $0 }.joined(separator: " ")
      let names = causes.map { cause in
        switch cause {
        case .proxy: "espera do proxy"
        case .fiveHour: "janela de 5 horas"
        case .weekly: "renovação da semana"
        }
      }
      let time = calendar.isDate(until, inSameDayAs: now) ? "às " : ""
      return "volta \(time)\(SubscriptionFormat.moment(until, now: now, calendar: calendar)), em \(span) (previsto pela "
        + names.joined(separator: " e ") + (partial ? "; semana não informada" : "") + ")"
    }
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
  /// order); then every stopped or exhausted account with a known return, the soonest first whatever its state or plan
  /// (rev. 2026-11-02: `20h` before `3d`); then those without one, stopped and then exhausted, needing login and
  /// unmeasured (each by plan, then the proxy's order). Consecutive accounts of one plan form a run, so a plan's label
  /// comes back when the order splits it. Balances order accounts only within one plan.
  public let runs: [Group]
  /// Ready subscriptions: a count of accounts, not of quota.
  public var ready: Int { groups.reduce(0) { $0 + $1.ready } }
  public var total: Int { groups.reduce(0) { $0 + $1.accounts.count } }
  public func count(_ kind: Kind) -> Int { groups.reduce(0) { $0 + $1.count(kind) } }
  /// The earliest time a blocked account is back, and how many come back within that minute.
  public let release: Release?
  /// The same over every account with a known wait, an exhausted one's weekly renewal included: the strip's counts
  /// fallback says when the next accounts are back (`+1 em 35m`). The details keep `release` and renewals apart.
  public let next: Release?
  /// The manual resets kept for later across these accounts; nil when none reports an inventory.
  public let resets: Resets?
  /// Enabled accounts the strip leaves out (Codex's Free accounts); the details still list them.
  public let hidden: Int

  /// The manual resets kept for later (`bankedResets.available`, what "Usar redefinição" spends), summed over the
  /// enabled accounts: never paid credits, the automatic reset or a count of accounts. `total` only when every one
  /// reports its inventory; with any missing, `missing` counts those and no total is claimed. A provider whose
  /// accounts report none has no `Resets`, so it never shows an invented 0.
  public struct Resets: Sendable, Equatable {
    public let total: Int?
    /// The sum over the accounts that report, for VoiceOver when the total is unknown.
    public let known: Int
    public let missing: Int
    /// Each account with resets and how many: `Iris 1`, `Kauri 2`.
    public let holders: [String]
    /// When the first of them expires, if the proxy says.
    public let expires: Date?

    init?(_ accounts: [Subscriptions.Account]) {
      let reports = accounts.compactMap(\.bankedResets)
      guard !reports.isEmpty else { return nil }
      known = Int(reports.reduce(0) { $0 + $1.available }.rounded())
      missing = accounts.count - reports.count
      total = missing == 0 ? known : nil
      holders = accounts.compactMap { account in
        account.bankedResets.flatMap { $0.available > 0 ? "\(account.name) \(Int($0.available.rounded()))" : nil }
      }
      expires = accounts.compactMap { account in
        account.bankedResets.flatMap { $0.available > 0 ? Subscriptions.date($0.earliestExpiresAt) : nil }
      }.min()
    }

    /// `redef. 3`, `redef. 0`, or `redef. ?` while an account does not report.
    public var label: String { "redef. " + (total.map(String.init) ?? "?") }

    /// `3 redefinições manuais disponíveis (Iris 1, Kauri 2), a primeira vence ter 03/11 08:53`.
    public func spoken(now: Date, calendar: Calendar = .current) -> String {
      guard let total else {
        return "redefinições manuais: total indisponível, \(missing) \(missing == 1 ? "conta sem dado" : "contas sem dado")"
          + " (\(known) nas que informam)"
      }
      if total == 0 { return "nenhuma redefinição manual disponível" }
      let expiry = expires.map { ", a primeira vence " + SubscriptionFormat.moment($0, now: now, calendar: calendar) } ?? ""
      return "\(total) \(total == 1 ? "redefinição manual disponível" : "redefinições manuais disponíveis")"
        + " (" + holders.joined(separator: ", ") + ")" + expiry
    }
  }

  public init(accounts: [Subscriptions.Account], pinned: String? = nil, now: Date, hidden: Int = 0) {
    let enabled = accounts.filter(\.enabled)
    resets = Resets(enabled)
    self.hidden = hidden
    let plans = enabled.reduce(into: [String?]()) { if !$0.contains($1.plan) { $0.append($1.plan) } }
    let built = plans.map { plan in
      // A plan the app has no name for keeps the proxy's own identifier, capitalized.
      let title = plan.map { Self.capitalized(Subscriptions.planLabel($0)) } ?? "Plano desconhecido"
      return Group(plan: plan, label: plan == nil ? "Outro" : Self.label(title), title: title,
        accounts: enabled.filter { $0.plan == plan }.map { account in
          let mark = SubscriptionMark(account, now: now)
          // Only over a fresh measurement: with old windows, the proxy's wait ending does not say the account is back.
          let stopped = (Kind(mark) == .blocked || Kind(mark) == .exhausted) && SubscriptionMark.fresh(account, now: now)
          return Account(id: account.id, name: account.name, mark: mark, pinned: account.id == pinned,
            balance: mark == .ready ? Balance(account) : nil, wait: stopped ? Wait(account, now: now) : nil)
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
    let waits = ordered.flatMap(\.accounts).compactMap(\.wait?.until)
    next = waits.min().map { first in Release(count: waits.filter { $0.timeIntervalSince(first) < 60 }.count, at: first) }
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

  /// State first; then what orders that state; the proxy's order last, so ties never swap between reads. A known
  /// return is the instant the strip counts down to (`Wait.until`, the end of the last blocker), never its rounded text.
  static func key(_ account: Account, plan: Double, position: Double) -> [Double] {
    if let wait = account.wait { return [1, wait.until.timeIntervalSince1970, plan, position] }
    return switch account.mark {
    case .ready: [0, plan, -Double(account.balance?.percent ?? 0), position]
    case .blocked: [2, plan, position, 0]
    case .exhausted: [3, plan, position, 0]
    case .attention: [4, plan, position, 0]
    case .unmeasured: [5, plan, position, 0]
    }
  }

  static func label(_ title: String) -> String {
    let multiplier = title.split(separator: " ").first { $0.count > 1 && $0.hasSuffix("x") && $0.dropLast().allSatisfy(\.isNumber) }
    return multiplier.map(String.init) ?? title
  }

  public static func capitalized(_ title: String) -> String { title.prefix(1).uppercased() + title.dropFirst() }

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

  /// The strip's summary after the marks or counts: when the next accounts are back (`+1 em 35m`, `+1 35m` when
  /// compact; for counts, the marks show their own waits) and the provider's manual resets (`redef. 3`). The ready
  /// accounts are the rings or `●×N`; `N prontas` comes back only for a provider that reports no resets. Empty when
  /// nothing fits.
  public func strip(now: Date, next: Bool, compact: Bool = false, resets: Bool = true) -> String {
    if total == 0 { return hidden > 0 ? "só contas Free" : "nenhuma conta" }
    let soon = next ? self.next.map { "+\($0.count) " + (compact ? "" : "em ") + Wait(until: $0.at, causes: []).short(now: now) } : nil
    guard let kept = self.resets else { return [summary(now: now, release: false), soon].compactMap { $0 }.joined(separator: " · ") }
    return [soon, resets ? kept.label : nil].compactMap { $0 }.joined(separator: " · ")
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
    let back = runs.flatMap(\.accounts).compactMap { account in
      account.wait.map { account.name + " " + $0.spoken(now: now, calendar: calendar) }
    }
    let waits = balances && !back.isEmpty ? ". Prazos: " + back.joined(separator: "; ") : ""
    let kept = balances ? resets.map { ". " + Self.capitalized($0.spoken(now: now, calendar: calendar)) } ?? "" : ""
    return "\(provider), \(ready) de \(total) assinaturas prontas agora. " + plans.joined(separator: ". ") + release
      + tail + waits + kept
  }
}

extension SubscriptionStore {
  /// The Sessões strip of a provider; nil until the proxy answers, or when its pool is not readable.
  public func marks(_ provider: SubscriptionProvider) -> SubscriptionMarks? {
    guard let snapshot, snapshot.pool(provider).status == "ok" else { return nil }
    return SubscriptionMarks(accounts: snapshot.pool(provider).accounts, pinned: selectedIDs[provider], now: now)
  }

  /// The Sessões strip: `marks` without Codex's Free accounts, which it leaves out of its marks, counts, resets and
  /// VoiceOver. Only what the strip shows: the accounts, the proxy and the details stay as they are.
  public func strip(_ provider: SubscriptionProvider) -> SubscriptionMarks? {
    guard let snapshot, snapshot.pool(provider).status == "ok" else { return nil }
    let accounts = snapshot.pool(provider).accounts
    let shown = SubscriptionMarks.strip(accounts, provider: provider)
    return SubscriptionMarks(accounts: shown, pinned: selectedIDs[provider], now: now,
      hidden: accounts.filter(\.enabled).count - shown.filter(\.enabled).count)
  }
}

extension SubscriptionMarks {
  static func strip(_ accounts: [Subscriptions.Account], provider: SubscriptionProvider) -> [Subscriptions.Account] {
    provider == .codex ? accounts.filter { $0.plan != "free" } : accounts
  }
}
