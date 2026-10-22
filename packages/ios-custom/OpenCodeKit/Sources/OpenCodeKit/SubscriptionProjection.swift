import Foundation

public enum SubscriptionCapacity: Sendable { case outside, unconfirmed, unavailable, available }
public enum SubscriptionTone: Sendable { case neutral, success, warning, danger }
public enum SubscriptionAccountState: Sendable, CaseIterable {
  case disabled, reauthenticate, cooldown, unconfirmed, outside, weeklyExhausted, fiveHourExhausted, noCapacity, available
  public var title: String {
    switch self {
    case .disabled: "Desativada"
    case .reauthenticate: "Reautenticação necessária"
    case .cooldown: "Em espera"
    case .unconfirmed: "Aguardando confirmação"
    case .outside: "Fora do pool"
    case .weeklyExhausted: "Cota semanal esgotada"
    case .fiveHourExhausted: "Limite de 5 horas"
    case .noCapacity: "Sem capacidade"
    case .available: "Disponível"
    }
  }
  public var tone: SubscriptionTone {
    switch self {
    case .reauthenticate, .weeklyExhausted: .danger
    case .cooldown, .fiveHourExhausted, .noCapacity: .warning
    case .available: .success
    default: .neutral
    }
  }
}

extension Subscriptions.Account {
  public var supported: Bool { ["promax", "pro", "prolite", "plus", "max20x", "max5x"].contains(plan) }
  public func renewalPassed(at now: Date) -> Bool {
    guard let observed = Subscriptions.date(observedAt) else { return false }
    return [resetAt, fiveHourResetAt].compactMap(Subscriptions.date).contains { observed < $0 && $0 <= now }
  }
  public func capacity(at now: Date) -> SubscriptionCapacity {
    if !supported { return .outside }
    if stale || hasCapacity == nil || renewalPassed(at: now) { return .unconfirmed }
    return hasCapacity == true ? .available : .unavailable
  }
  public func value(_ value: Double?, at now: Date) -> Double? {
    stale || capacity(at: now) == .unconfirmed ? nil : value
  }
  public func state(at now: Date) -> SubscriptionAccountState {
    if !enabled { return .disabled }
    if !authenticated { return .reauthenticate }
    if cooldownSeconds > 0 { return .cooldown }
    if capacity(at: now) == .unconfirmed { return .unconfirmed }
    if capacity(at: now) == .outside { return .outside }
    if value(remaining, at: now) == 0 { return .weeklyExhausted }
    if capacity(at: now) == .unavailable && fiveHourRemaining == 0 { return .fiveHourExhausted }
    if capacity(at: now) == .unavailable { return .noCapacity }
    return .available
  }
  public func pace(at now: Date) -> Double? {
    guard remaining != nil, capacity(at: now) != .unconfirmed, let reset = Subscriptions.date(resetAt) else { return nil }
    let interval = reset.timeIntervalSince(now)
    return interval > 0 && interval <= 7 * 86_400 ? interval / (7 * 86_400) * 100 : nil
  }
  fileprivate var planRank: Int {
    switch plan {
    case "promax": 0
    case "pro", "max20x": 1
    case "prolite", "max5x": 2
    case "plus": 3
    default: 4
    }
  }
  fileprivate func rank(at now: Date) -> Int {
    if !supported { return 2 }
    return enabled && authenticated && cooldownSeconds <= 0 && capacity(at: now) == .available ? 0 : 1
  }
}

public struct SubscriptionProjection: Sendable {
  public enum Balance: Sendable { case empty, unknown, unavailable, known }
  public struct Inventory: Sendable {
    public let available: Double
    public let nonExpiring: Double
    public let earliest: Date?
    public let latest: Date?
  }
  public let total: Int
  public let measured: Int
  public let ready: Int
  public let balance: Balance
  public let equivalents: Double?
  public let remaining: Double?
  public let fiveHourRemaining: Double?
  public let expectedRemaining: Double?
  public let observedAt: Date?
  public let inventory: Inventory?
  public let renewal: Date?

  public static func includes(_ plan: String?, in pool: String) -> Bool {
    plan == pool || (pool == "pro" && plan == "promax")
  }
  public static func sorted(_ accounts: [Subscriptions.Account], now: Date) -> [Subscriptions.Account] {
    accounts.enumerated().sorted {
      if $0.element.planRank != $1.element.planRank { return $0.element.planRank < $1.element.planRank }
      if $0.element.rank(at: now) != $1.element.rank(at: now) { return $0.element.rank(at: now) < $1.element.rank(at: now) }
      return $0.offset < $1.offset
    }.map(\.element)
  }
  public init(accounts: [Subscriptions.Account], plan: String, now: Date) {
    let members = accounts.filter { Self.includes($0.plan, in: plan) && $0.enabled && $0.authenticated }
    let measurements = members.filter { !$0.stale && $0.remaining != nil && !$0.renewalPassed(at: now) }
    let usable = members.filter { !$0.stale && $0.hasCapacity == true && $0.cooldownSeconds <= 0 && !$0.renewalPassed(at: now) }
    let uncertain = members.contains { $0.remaining == nil || $0.capacity(at: now) == .unconfirmed }
    let sum = !uncertain && !members.isEmpty ? members.reduce(0) { $0 + ($1.remaining ?? 0) } : nil
    let paces = members.compactMap { $0.pace(at: now) }
    let observations = measurements.compactMap { Subscriptions.date($0.observedAt) }
    let inventories = members.compactMap(\.bankedResets)
    total = members.count
    measured = measurements.count
    ready = usable.count
    balance = members.isEmpty ? .empty : uncertain ? .unknown : usable.isEmpty ? .unavailable : .known
    equivalents = sum.map { $0 / 100 }
    remaining = sum.map { $0 / Double(members.count) }
    fiveHourRemaining = !members.isEmpty && members.allSatisfy {
      !$0.stale && $0.fiveHourRemaining != nil && !$0.renewalPassed(at: now)
    } ? members.reduce(0) { $0 + ($1.fiveHourRemaining ?? 0) } / Double(members.count) : nil
    expectedRemaining = !uncertain && !members.isEmpty && paces.count == members.count
      ? paces.reduce(0, +) / Double(paces.count) : nil
    observedAt = !observations.isEmpty && observations.count == measurements.count ? observations.min() : nil
    inventory = !members.isEmpty && inventories.count == members.count ? Inventory(
      available: inventories.reduce(0) { $0 + $1.available },
      nonExpiring: inventories.reduce(0) { $0 + $1.nonExpiring },
      earliest: inventories.compactMap { Subscriptions.date($0.earliestExpiresAt) }.min(),
      latest: inventories.compactMap { Subscriptions.date($0.latestExpiresAt) }.max()) : nil
    renewal = members.compactMap { Subscriptions.date($0.resetAt) }.min()
  }
}

public enum SubscriptionFormat {
  public static func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
  public static func number(_ value: Double?, decimals: Int = 2) -> String {
    value?.formatted(.number.locale(Locale(identifier: "pt_BR")).precision(.fractionLength(decimals))) ?? "—"
  }
  public static func resets(_ value: Double) -> String {
    "\(number(value, decimals: 0)) \(value == 1 ? "redefinição" : "redefinições")"
  }
  public static func date(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")
    formatter.dateFormat = "dd/MM 'às' HH:mm"
    return formatter.string(from: date)
  }
  public static func countdown(_ date: Date?, now: Date) -> String {
    guard let date else { return "—" }
    let seconds = max(0, date.timeIntervalSince(now))
    if seconds >= 86_400 { return number(seconds / 86_400, decimals: 1) + "d" }
    if seconds >= 3600 { return "\(Int(seconds / 3600))h" }
    return "\(Int(ceil(seconds / 60)))min"
  }
  public static func tone(_ value: Double?) -> SubscriptionTone {
    guard let value else { return .neutral }
    if value < 10 { return .danger }
    if value < 30 { return .warning }
    return .neutral
  }
}
