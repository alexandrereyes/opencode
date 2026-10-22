import Foundation
import OpenCodeKit

func subscriptionClient(configuration: ServerConfiguration, client: OpenCodeClient) -> any SubscriptionClient {
  #if DEBUG
  if configuration.url.absoluteString == "http://127.0.0.1:4177",
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
#endif
