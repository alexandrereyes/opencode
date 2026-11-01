import Foundation
import OpenCodeKit

func subscriptionClient(configuration: ServerConfiguration, client: OpenCodeClient) -> any SubscriptionClient {
  #if DEBUG
  if configuration.isolatedTestSandbox,
     let scenario = ProcessInfo.processInfo.environment["OPENCODE_PROXY_STUB"] {
    return SubscriptionTestClient(scenario: scenario)
  }
  #endif
  return client
}

#if DEBUG
// This client never forwards mutations or reads to a server, including after a test failure.
private actor SubscriptionTestClient: SubscriptionClient {
  let scenario: String
  var automatic = false
  var resets: Double = 2
  init(scenario: String) { self.scenario = scenario }
  func subscriptions() async throws -> Subscriptions {
    if scenario == "marks" || scenario == "many" { return SubscriptionMarksFixture.snapshot(many: scenario == "many", now: .now) }
    if scenario == "unavailable" { return .unavailable }
    if scenario == "unconfigured" { return .init(status: "unconfigured") }
    let now = Date.now
    let formatter = ISO8601DateFormatter()
    let first = Subscriptions.Account(id: "test-pro", name: "Conta de teste", remaining: 80,
      resetAt: formatter.string(from: now.addingTimeInterval(86_400 * 3)), fiveHourRemaining: 70,
      fiveHourResetAt: formatter.string(from: now.addingTimeInterval(3600 * 2)),
      observedAt: formatter.string(from: now), hasCapacity: true, bankedResets: .init(available: resets))
    var second = first
    second.id = "test-exhausted"; second.name = "Conta sem cota"; second.remaining = 0; second.hasCapacity = false
    var claude = first
    claude.id = "test-claude"; claude.plan = "max20x"
    return .init(status: "ok", accounts: [first, second], automation: .init(enabled: automatic),
      anthropic: .init(status: "ok", accounts: [claude], automation: .init(enabled: automatic)))
  }
  func setSubscriptionAutomation(_ provider: SubscriptionProvider, enabled: Bool) async throws -> Subscriptions.Automation {
    try await Task.sleep(for: .seconds(scenario == "pending" ? 90 : 1))
    if scenario == "error" { throw ClientError.rpc("update_failed") }
    automatic = enabled
    return .init(enabled: enabled)
  }
  func consumeSubscriptionReset(_ provider: SubscriptionProvider, accountID: String) async throws -> SubscriptionResetResult {
    try await Task.sleep(for: .seconds(scenario == "pending" ? 90 : 1))
    if ["error", "busy", "no_credit"].contains(scenario) { throw ClientError.rpc(scenario == "error" ? "consume_failed" : scenario) }
    resets -= 1
    return .init(code: "test", windowsReset: 1)
  }
}

/// The Sessões strip fixture, shared by the iPhone stub (`OPENCODE_PROXY_STUB=marks|many`) and the Mac fixture
/// (`-OpenCodeMacProxyScenario marks|many`). `marks`: Claude with five Max 5x (four ready, one stopped by the
/// 5-hour window, whose weekly window is still open) and two Max 20x with the week exhausted; Codex with a ready Pro
/// Max, a Pro 5x stopped by the 5-hour window, an exhausted Pro 5x and two Free accounts the proxy accepts without
/// measuring. The LLM proxy details read the same accounts: the Pro Max one also reports its 5-hour window and paid
/// credits, the stopped Pro 5x a banked reset, the exhausted one renews first, and the stopped Max 5x is in the
/// proxy's wait. `many` adds enough accounts and plans for the strip to fall back to counts.
enum SubscriptionMarksFixture {
  static func snapshot(many: Bool, now: Date) -> Subscriptions {
    func at(_ offset: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    func account(_ id: String, plan: String?, weekly: Double?, fiveHour: Double?, capacity: Bool? = true,
                 fiveHourReset: Double = 3 * 3_600, cooldown: Double = 0, weeklyReset: Double = 3 * 86_400,
                 credits: Double? = nil, resets: Subscriptions.BankedResets? = nil) -> Subscriptions.Account {
      Subscriptions.Account(id: id, name: id.capitalized, plan: plan, remaining: weekly,
        resetAt: weekly == nil ? nil : at(weeklyReset), fiveHourRemaining: fiveHour,
        fiveHourResetAt: fiveHour == nil ? nil : at(fiveHourReset), observedAt: at(-300), hasCapacity: capacity,
        cooldownSeconds: cooldown, credits: credits, bankedResets: resets)
    }
    var claude = [
      account("atlas", plan: "max5x", weekly: 72, fiveHour: 100, resets: .init(available: 2, nonExpiring: 2)),
      account("brisa", plan: "max5x", weekly: nil, fiveHour: 100),
      account("cedro", plan: "max5x", weekly: 64, fiveHour: 92),
      account("duna", plan: "max5x", weekly: 41, fiveHour: 69),
      account("eco", plan: "max5x", weekly: 58, fiveHour: 0, capacity: false, fiveHourReset: 6_600, cooldown: 6_600),
      account("farol", plan: "max20x", weekly: 0, fiveHour: nil, capacity: false),
      account("gavea", plan: "max20x", weekly: 0, fiveHour: nil, capacity: false),
    ]
    var codex = [
      account("iris", plan: "promax", weekly: 81, fiveHour: 64, fiveHourReset: 12_900, weeklyReset: 6.4 * 86_400,
        credits: 21_877, resets: .init(available: 0)),
      account("kauri", plan: "prolite", weekly: 54, fiveHour: 0, capacity: false, fiveHourReset: 9_300,
        weeklyReset: 3.9 * 86_400, resets: .init(available: 1, earliestExpiresAt: at(5.2 * 86_400))),
      account("jade", plan: "prolite", weekly: 0, fiveHour: nil, capacity: false, weeklyReset: 1.9 * 86_400,
        resets: .init(available: 0)),
      account("lume", plan: "free", weekly: nil, fiveHour: nil),
      account("mira", plan: "free", weekly: nil, fiveHour: nil),
    ]
    if many {
      claude += (1...11).map { account("extra\($0)", plan: "max5x", weekly: 50, fiveHour: $0 % 3 == 0 ? 0 : 80,
        capacity: $0 % 3 != 0, fiveHourReset: Double($0) * 900) }
      claude += [account("novo", plan: nil, weekly: 90, fiveHour: 90), account("time", plan: "team", weekly: nil, fiveHour: 40)]
      var stale = account("velha", plan: "prolite", weekly: 30, fiveHour: 30)
      stale.stale = true
      var login = account("sem-login", plan: "promax", weekly: 70, fiveHour: 70)
      login.authenticated = false
      codex += [stale, login, account("plus", plan: "plus", weekly: 33, fiveHour: 60)]
        + (1...6).map { account("free\($0)", plan: "free", weekly: nil, fiveHour: nil) }
    }
    return Subscriptions(status: "ok", accounts: codex, automation: .init(enabled: false),
      anthropic: .init(status: "ok", accounts: claude, automation: .init(enabled: false)))
  }
}
#endif
