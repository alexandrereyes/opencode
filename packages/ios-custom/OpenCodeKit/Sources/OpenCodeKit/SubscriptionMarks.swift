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
  }
  public struct Group: Sendable, Identifiable {
    public let plan: String?
    /// The plan's multiplier when its label has one (`5x`, `20x`), else the label itself (`Pro Max`, `Free`).
    public let label: String
    /// The full plan name for VoiceOver.
    public let title: String
    public let accounts: [Account]
    public var id: String { plan ?? "" }
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
        accounts: enabled.filter { $0.plan == plan }.map {
          Account(id: $0.id, name: $0.name, mark: SubscriptionMark($0, now: now), pinned: $0.id == pinned)
        })
    }
    let ordered = built.filter { $0.count(.unmeasured) < $0.accounts.count }
      + built.filter { $0.count(.unmeasured) == $0.accounts.count }
    groups = ordered
    let releases = ordered.flatMap(\.accounts).compactMap { account -> Date? in
      if case .blocked(let until) = account.mark { return until }
      return nil
    }
    release = releases.min().map { first in
      Release(count: releases.filter { $0.timeIntervalSince(first) < 60 }.count, at: first)
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

  /// VoiceOver: every plan with its accounts by state, then the release.
  public func spoken(_ provider: String, now: Date, calendar: Calendar = .current) -> String {
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
    return "\(provider), \(ready) de \(total) assinaturas prontas agora. " + plans.joined(separator: ". ") + release
  }
}

extension SubscriptionStore {
  /// The Sessões strip of a provider; nil until the proxy answers, or when its pool is not readable.
  public func marks(_ provider: SubscriptionProvider) -> SubscriptionMarks? {
    guard let snapshot, snapshot.pool(provider).status == "ok" else { return nil }
    return SubscriptionMarks(accounts: snapshot.pool(provider).accounts, pinned: selectedIDs[provider], now: now)
  }
}
