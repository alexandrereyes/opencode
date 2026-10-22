import Foundation

public enum SubscriptionProvider: String, Codable, CaseIterable, Sendable, Identifiable {
  case codex, anthropic
  public var id: String { rawValue }
  public var title: String { self == .codex ? "Codex" : "Claude" }
  public var plan: String { self == .codex ? "pro" : "max20x" }
  public var unit: String { Subscriptions.planLabel(plan) }
}

public struct Subscriptions: Codable, Sendable {
  public var status: String
  public var accounts: [Account]
  public var automation: Automation?
  public var anthropic: Pool

  public init(status: String, accounts: [Account] = [], automation: Automation? = nil,
              anthropic: Pool = .init(status: "disabled")) {
    self.status = status
    self.accounts = accounts
    self.automation = automation
    self.anthropic = anthropic
  }
  public struct Pool: Codable, Sendable {
    public var status: String
    public var accounts: [Account]
    public var automation: Automation?
    public init(status: String, accounts: [Account] = [], automation: Automation? = nil) {
      self.status = status
      self.accounts = accounts
      self.automation = automation
    }
  }
  public struct Automation: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
  }
  public struct BankedResets: Codable, Sendable, Equatable {
    public var available: Double
    public var earliestExpiresAt: String?
    public var latestExpiresAt: String?
    public var nonExpiring: Double
    public init(available: Double, earliestExpiresAt: String? = nil, latestExpiresAt: String? = nil,
                nonExpiring: Double = 0) {
      self.available = available
      self.earliestExpiresAt = earliestExpiresAt
      self.latestExpiresAt = latestExpiresAt
      self.nonExpiring = nonExpiring
    }
  }
  public struct Account: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var authenticated: Bool
    public var plan: String?
    public var remaining: Double?
    public var resetAt: String?
    public var fiveHourRemaining: Double?
    public var fiveHourResetAt: String?
    public var observedAt: String?
    public var stale: Bool
    public var hasCapacity: Bool?
    public var cooldownSeconds: Double
    public var credits: Double?
    public var bankedResets: BankedResets?

    public init(id: String, name: String, enabled: Bool = true, authenticated: Bool = true,
                plan: String? = "pro", remaining: Double? = nil, resetAt: String? = nil,
                fiveHourRemaining: Double? = nil, fiveHourResetAt: String? = nil,
                observedAt: String? = nil, stale: Bool = false, hasCapacity: Bool? = nil,
                cooldownSeconds: Double = 0, credits: Double? = nil, bankedResets: BankedResets? = nil) {
      self.id = id
      self.name = name
      self.enabled = enabled
      self.authenticated = authenticated
      self.plan = plan
      self.remaining = remaining
      self.resetAt = resetAt
      self.fiveHourRemaining = fiveHourRemaining
      self.fiveHourResetAt = fiveHourResetAt
      self.observedAt = observedAt
      self.stale = stale
      self.hasCapacity = hasCapacity
      self.cooldownSeconds = cooldownSeconds
      self.credits = credits
      self.bankedResets = bankedResets
    }
  }

  public func pool(_ provider: SubscriptionProvider) -> Pool {
    provider == .codex ? Pool(status: status, accounts: accounts, automation: automation) : anthropic
  }
  public static let unavailable = Self(status: "unavailable", anthropic: .init(status: "unavailable"))
  public static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  public static func planLabel(_ plan: String?) -> String {
    switch plan {
    case "promax": "Pro Max"
    case "pro": "Pro 20x"
    case "prolite": "Pro 5x"
    case "plus": "Plus"
    case "max20x": "Max 20x"
    case "max5x": "Max 5x"
    default: plan ?? "Plano desconhecido"
    }
  }
  public struct Summary: Sendable {
    public let remaining: Double?
    public let reset: Date?
    public let ready: Bool
    public func label(_ name: String, now: Date = .now) -> String {
      let percent = SubscriptionFormat.percent(remaining)
      let days = reset.map {
        max(0, $0.timeIntervalSince(now) / 86_400).formatted(
          .number.locale(Locale(identifier: "pt_BR")).precision(.fractionLength(1))) + "d"
      } ?? "—"
      return "\(name) \(percent) · \(days)"
    }
  }
}

public protocol SubscriptionClient: Sendable {
  func subscriptions() async throws -> Subscriptions
  func setSubscriptionAutomation(_ provider: SubscriptionProvider, enabled: Bool) async throws -> Subscriptions.Automation
  func consumeSubscriptionReset(_ provider: SubscriptionProvider, accountID: String) async throws -> SubscriptionResetResult
}

public struct SubscriptionResetResult: Codable, Sendable {
  public let code: String
  public let windowsReset: Double
  public init(code: String, windowsReset: Double) { self.code = code; self.windowsReset = windowsReset }
}

extension OpenCodeClient: SubscriptionClient {
  public func setSubscriptionAutomation(_ provider: SubscriptionProvider, enabled: Bool) async throws -> Subscriptions.Automation {
    struct Input: Encodable { let provider: SubscriptionProvider; let enabled: Bool }
    return try await rpc("custom.subscriptions", "setAutomation", input: Input(provider: provider, enabled: enabled))
  }
  public func consumeSubscriptionReset(_ provider: SubscriptionProvider, accountID: String) async throws -> SubscriptionResetResult {
    struct Input: Encodable { let provider: SubscriptionProvider; let accountId: String }
    struct Body: Encodable { let input: Input }
    struct Output: Decodable { let output: SubscriptionResetResult }
    var request = request("/api/rpc/custom.subscriptions/consumeReset")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(Body(input: Input(provider: provider, accountId: accountID)))
    // The proxy can spend ~75s observing both sides of the reset; its own budget is 90s.
    request.timeoutInterval = 110
    return try JSONDecoder().decode(Output.self, from: await data(request)).output
  }
}
