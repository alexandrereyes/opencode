import Foundation

/// A provider's LLM proxy details ("Agora primeiro", rev. 2026-11-01): the Sessões strip's `SubscriptionMarks` with
/// what each account shows below it. Every account of every plan is listed, disabled ones included (the strip leaves
/// them out); a percent is always one window of one account, an unknown value stays unknown, and plans only identify.
public struct SubscriptionDetails: Sendable {
  /// One window of one account: the remaining percent (nil when unknown or no longer fresh) and its next reset.
  public struct Window: Sendable, Equatable {
    public let remaining: Double?
    public let resetAt: Date?
    /// This window keeps the account out now: the 5-hour window measured at 0, or the week of an exhausted account.
    public let blocking: Bool
  }
  /// Why a stopped account is stopped, as far as the data says.
  public enum Cause: Sendable, Equatable {
    /// The 5-hour window measured at 0.
    case fiveHour
    /// The proxy's own wait (`cooldownSeconds`), which does not say which window caused it.
    case wait
    /// A refusal the windows do not explain.
    case unexplained
  }
  public struct Account: Sendable, Identifiable {
    public let account: Subscriptions.Account
    /// Nil for a disabled account, which the proxy does not use and the strip leaves out.
    public let mark: SubscriptionMark?
    public let pinned: Bool
    /// Nil when the account reports nothing for that window, and the 5-hour one once the week is exhausted.
    public let fiveHour: Window?
    public let weekly: Window?
    public let cause: Cause?
    public var id: String { account.id }
    public var name: String { account.name }
    /// Nothing to show but its name and state: no window, credits or resets to use.
    public var compact: Bool {
      fiveHour == nil && weekly == nil && account.credits == nil && (account.bankedResets?.available ?? 0) == 0
    }
  }
  public struct Group: Sendable, Identifiable {
    public let plan: String?
    /// The full plan name (`Pro Max`, `Max 5x`), as in the strip's VoiceOver text.
    public let title: String
    public let accounts: [Account]
    public var id: String { plan ?? "" }
    public var enabled: [Account] { accounts.filter { $0.mark != nil } }
    public var ready: Int { accounts.filter { $0.mark == .ready }.count }
    public var disabled: Int { accounts.count - enabled.count }
    /// Every enabled account without a measurement (Free accounts today).
    public var unmeasured: Bool { !enabled.isEmpty && enabled.allSatisfy { $0.mark == .unmeasured } }
    /// The earliest known release among this plan's stopped accounts.
    public var release: Date? {
      enabled.compactMap { if case .blocked(let until) = $0.mark { return until } else { return nil } }.min()
    }
  }
  /// When the next stopped account is back: which ones (within that minute) and why.
  public struct Release: Sendable, Equatable {
    public let at: Date
    public let names: [String]
    public let cause: Cause?
  }
  /// The next weekly renewal among the accounts that report one. It is not a release: an account the week does not
  /// block is unaffected by it.
  public struct Renewal: Sendable, Equatable {
    public let at: Date
    public let names: [String]
  }
  /// Banked resets: their sum across the accounts that report an inventory, never a quota.
  public struct Resets: Sendable, Equatable {
    public let available: Double
    public let accounts: Int
    public let unknown: Int
    public let earliest: Date?
  }

  public let marks: SubscriptionMarks
  public let groups: [Group]
  public let release: Release?
  /// Stopped accounts whose end is unknown.
  public let stoppedWithoutTime: Int
  public let renewal: Renewal?
  /// The oldest measurement among the enabled accounts that report one.
  public let observedAt: Date?
  public let resets: Resets

  public init(accounts: [Subscriptions.Account], pinned: String? = nil, now: Date) {
    let marks = SubscriptionMarks(accounts: accounts, pinned: pinned, now: now)
    self.marks = marks
    let rows = Dictionary(accounts.map { account in
      (account.id, Self.row(account, mark: account.enabled ? SubscriptionMark(account, now: now) : nil,
                            pinned: account.id == pinned, now: now))
    }, uniquingKeysWith: { first, _ in first })
    // The strip's plan order (the proxy's, unmeasured plans last), each plan's disabled accounts after its others,
    // and plans with only disabled accounts at the end.
    let disabled = accounts.filter { !$0.enabled }
    let measured = marks.groups.map { group in
      Group(plan: group.plan, title: group.title,
            accounts: group.accounts.compactMap { rows[$0.id] } + disabled.filter { $0.plan == group.plan }.compactMap { rows[$0.id] })
    }
    let rest = disabled.filter { account in !marks.groups.contains { $0.plan == account.plan } }
    let others = rest.reduce(into: [String?]()) { if !$0.contains($1.plan) { $0.append($1.plan) } }.map { plan in
      Group(plan: plan, title: plan.map { SubscriptionMarks.capitalized(Subscriptions.planLabel($0)) } ?? "Plano desconhecido",
            accounts: rest.filter { $0.plan == plan }.compactMap { rows[$0.id] })
    }
    groups = measured + others
    let stopped = groups.flatMap(\.enabled).compactMap { row -> (Account, Date?)? in
      if case .blocked(let until) = row.mark { return (row, until) }
      return nil
    }
    stoppedWithoutTime = stopped.filter { $0.1 == nil }.count
    release = marks.release.map { release in
      let back = stopped.filter { $0.1.map { $0.timeIntervalSince(release.at) < 60 } ?? false }.map(\.0)
      let causes = Set(back.compactMap(\.cause))
      return Release(at: release.at, names: back.map(\.name), cause: causes.count == 1 ? causes.first : nil)
    }
    let renewals = groups.flatMap(\.enabled).compactMap { row in row.weekly?.resetAt.map { (row.name, $0) } }
    renewal = renewals.map(\.1).min().map { first in
      Renewal(at: first, names: renewals.filter { $0.1.timeIntervalSince(first) < 60 }.map(\.0))
    }
    observedAt = accounts.filter(\.enabled).compactMap { Subscriptions.date($0.observedAt) }.min()
    let inventories = accounts.filter(\.enabled).compactMap(\.bankedResets)
    resets = Resets(available: inventories.reduce(0) { $0 + $1.available }, accounts: inventories.count,
                    unknown: accounts.filter(\.enabled).count - inventories.count,
                    earliest: inventories.filter { $0.available > 0 }.compactMap { Subscriptions.date($0.earliestExpiresAt) }.min())
  }

  private static func row(_ account: Subscriptions.Account, mark: SubscriptionMark?, pinned: Bool, now: Date) -> Account {
    // The strip's freshness: a stale or unconfirmed measurement, or one taken before a renewal that has passed, shows
    // no percent at all rather than an old or zero one.
    let fresh = !account.stale && account.hasCapacity != nil && !account.renewalPassed(at: now)
    func upcoming(_ value: String?) -> Date? { Subscriptions.date(value).flatMap { $0 > now ? $0 : nil } }
    let exhausted = mark == .exhausted
    let fiveHourValue = fresh ? account.fiveHourRemaining : nil
    let fiveHour = exhausted || (account.fiveHourRemaining == nil && account.fiveHourResetAt == nil) ? nil
      : Window(remaining: fiveHourValue, resetAt: upcoming(account.fiveHourResetAt), blocking: fiveHourValue == 0)
    let weekly = account.remaining == nil && account.resetAt == nil ? nil
      : Window(remaining: fresh ? account.remaining : nil, resetAt: upcoming(account.resetAt), blocking: exhausted)
    let cause: Cause? = {
      guard case .blocked = mark else { return nil }
      if account.cooldownSeconds > 0 { return .wait }
      return fiveHourValue == 0 ? .fiveHour : .unexplained
    }()
    return Account(account: account, mark: mark, pinned: pinned, fiveHour: fiveHour, weekly: weekly, cause: cause)
  }
}

extension SubscriptionFormat {
  /// A time in the details: `11:15` today, else `ter 03/11 08:53`.
  public static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.timeZone = calendar.timeZone
    if calendar.isDate(date, inSameDayAs: now) {
      formatter.dateFormat = "HH:mm"
      return formatter.string(from: date)
    }
    formatter.dateFormat = "EEE"
    let weekday = formatter.string(from: date).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    formatter.dateFormat = "dd/MM HH:mm"
    return weekday + " " + formatter.string(from: date)
  }

  /// How old the oldest measurement is: `medido agora`, `medição mais antiga há 4 min`, `… há 2 h`.
  public static func age(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes == 0 { return "Medido agora" }
    return "Medição mais antiga há " + (minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h")
  }
}

extension SubscriptionStore {
  /// The details of a provider; nil until the proxy answers, or when its pool is not readable.
  public func details(_ provider: SubscriptionProvider) -> SubscriptionDetails? {
    guard let snapshot, snapshot.pool(provider).status == "ok" else { return nil }
    return SubscriptionDetails(accounts: snapshot.pool(provider).accounts, pinned: selectedIDs[provider], now: now)
  }
}
