import Foundation

public struct Subscriptions: Codable, Sendable {
  public let status: String
  public let accounts: [Account]
  public let anthropic: Pool

  public struct Pool: Codable, Sendable {
    public let status: String
    public let accounts: [Account]
  }
  public struct Account: Codable, Sendable {
    public let enabled: Bool
    public let authenticated: Bool
    public let plan: String?
    public let remaining: Double?
    public let resetAt: String?
    public let fiveHourResetAt: String?
    public let observedAt: String?
    public let stale: Bool
    public let hasCapacity: Bool?
    public let cooldownSeconds: Double
  }

  public func summary(anthropic: Bool, now: Date = .now) -> Summary {
    let pool = anthropic ? self.anthropic.accounts : accounts
    let members = pool.filter {
      $0.enabled && $0.authenticated
        && ($0.plan == (anthropic ? "max20x" : "pro") || (!anthropic && $0.plan == "promax"))
    }
    let known =
      !members.isEmpty
      && members.allSatisfy { account in
        guard !account.stale, account.remaining != nil, account.hasCapacity != nil else {
          return false
        }
        guard let observed = Self.date(account.observedAt) else { return true }
        return ![account.resetAt, account.fiveHourResetAt].compactMap(Self.date).contains {
          observed < $0 && $0 <= now
        }
      }
    return Summary(
      remaining: known
        ? members.reduce(0) { $0 + ($1.remaining ?? 0) } / Double(members.count) : nil,
      reset: members.compactMap { Self.date($0.resetAt) }.min(),
      ready: members.contains { !$0.stale && $0.hasCapacity == true && $0.cooldownSeconds <= 0 }
    )
  }
  private static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  public struct Summary: Sendable {
    public let remaining: Double?
    public let reset: Date?
    public let ready: Bool
    public func label(_ name: String, now: Date = .now) -> String {
      let percent = remaining.map { "\(Int($0.rounded()))%" } ?? "—"
      let days =
        reset.map {
          max(0, $0.timeIntervalSince(now) / 86_400).formatted(
            .number.locale(Locale(identifier: "pt_BR")).precision(.fractionLength(1))) + "d"
        } ?? "—"
      return "\(name) \(percent) · \(days)"
    }
  }
}
