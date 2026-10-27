#if DEBUG
import Foundation
import OpenCodeKit

/// The fixture's LLM proxy (`custom.subscriptions`): Codex and Claude with accounts in every state, credits,
/// resets with and without expiry, and automation on for Claude only. "Usar redefinição" and the automation
/// switch change this in-memory state after a delay, so "Aplicando…" can be seen; nothing reaches a proxy.
/// `-OpenCodeMacProxyScenario loading|error|empty` answers the list read with a request that never ends, a
/// failure, or no accounts.
actor MacFixtureProxy {
  private let scenario = MacFixture.value("-OpenCodeMacProxyScenario")
  private let now: Date
  private var codex: [Subscriptions.Account]
  private var claude: [Subscriptions.Account]
  private var automation: [SubscriptionProvider: Bool] = [.codex: false, .anthropic: true]

  init(now: Date) {
    self.now = now
    let hour = 3_600.0
    let day = 86_400.0
    func at(_ offset: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    func account(_ id: String, _ name: String, plan: String, weekly: Double?, fiveHour: Double?, resets: Double,
      expires: Double? = nil, capacity: Bool? = true) -> Subscriptions.Account {
      Subscriptions.Account(id: id, name: name, plan: plan, remaining: weekly, resetAt: at(3 * day - 2 * hour),
        fiveHourRemaining: fiveHour, fiveHourResetAt: at(2 * hour), observedAt: at(-4 * 60), hasCapacity: capacity,
        bankedResets: .init(available: resets, earliestExpiresAt: expires.map(at), latestExpiresAt: expires.map(at),
          nonExpiring: expires == nil ? resets : 0))
    }
    var waiting = account("codex-espera", "Conta em espera", plan: "pro", weekly: 52, fiveHour: 44, resets: 0)
    waiting.cooldownSeconds = 420
    var off = account("codex-antiga", "Conta antiga", plan: "pro", weekly: 90, fiveHour: 100, resets: 0)
    off.enabled = false
    var plus = account("codex-plus", "Conta Plus", plan: "plus", weekly: 38, fiveHour: 70, resets: 1, expires: 6 * day)
    plus.stale = true
    plus.observedAt = at(-3 * hour)
    plus.credits = 1_250
    var trial = account("codex-teste", "Conta de teste", plan: "pro", weekly: 80, fiveHour: 70, resets: 2)
    trial.observedAt = at(-12 * 60)
    codex = [
      trial,
      account("codex-sem-cota", "Conta sem cota", plan: "pro", weekly: 0, fiveHour: 40, resets: 0, capacity: false),
      account("codex-reserva", "Conta reserva", plan: "pro", weekly: 64, fiveHour: 95, resets: 1, expires: 2 * day + 5 * hour),
      account("codex-trabalho", "Conta trabalho", plan: "pro", weekly: 30, fiveHour: 0, resets: 0, capacity: false),
      waiting, off, plus,
    ]
    var main = account("claude-principal", "Claude principal", plan: "max20x", weekly: 61, fiveHour: 48, resets: 3,
      expires: 9 * day)
    main.bankedResets = .init(available: 3, earliestExpiresAt: at(26 * hour), latestExpiresAt: at(9 * day), nonExpiring: 1)
    var spare = account("claude-reserva", "Claude reserva", plan: "max20x", weekly: 22, fiveHour: 8, resets: 0)
    spare.credits = 40
    var login = account("claude-login", "Claude estúdio", plan: "max20x", weekly: 70, fiveHour: 90, resets: 0)
    login.authenticated = false
    claude = [main, spare, login,
      account("claude-pessoal", "Claude pessoal", plan: "max5x", weekly: 92, fiveHour: 100, resets: 1)]
  }

  func respond(_ method: String, _ input: [String: JSONValue]?) async -> String? {
    switch method {
    case "list":
      switch scenario {
      case "loading": try? await Task.sleep(for: .seconds(3_600)); return nil
      case "error": return nil
      default: return output(snapshot)
      }
    case "setAutomation":
      try? await Task.sleep(for: .seconds(2))
      let provider = SubscriptionProvider(rawValue: input?["provider"]?.string ?? "") ?? .codex
      let enabled = input?["enabled"] == .bool(true)
      automation[provider] = enabled
      return output(Subscriptions.Automation(enabled: enabled))
    case "consumeReset":
      try? await Task.sleep(for: .seconds(MacFixture.value("-OpenCodeMacProxyResetSeconds").flatMap(Double.init) ?? 6))
      let provider = SubscriptionProvider(rawValue: input?["provider"]?.string ?? "") ?? .codex
      let id = input?["accountId"]?.string ?? ""
      if provider == .codex { codex = consume(codex, id) } else { claude = consume(claude, id) }
      return output(SubscriptionResetResult(code: "ok", windowsReset: 1))
    default:
      return nil
    }
  }

  private var snapshot: Subscriptions {
    if scenario == "empty" {
      return Subscriptions(status: "ok", automation: .init(enabled: false), anthropic: .init(status: "ok", automation: .init(enabled: false)))
    }
    return Subscriptions(status: "ok", accounts: codex, automation: .init(enabled: automation[.codex] ?? false),
      anthropic: .init(status: "ok", accounts: claude, automation: .init(enabled: automation[.anthropic] ?? false)))
  }

  /// A reset spends one banked reset and refills both windows.
  private func consume(_ accounts: [Subscriptions.Account], _ id: String) -> [Subscriptions.Account] {
    accounts.map { account in
      guard account.id == id, var banked = account.bankedResets, banked.available > 0 else { return account }
      var next = account
      banked.available -= 1
      banked.nonExpiring = min(banked.nonExpiring, banked.available)
      next.bankedResets = banked
      next.remaining = 100
      next.fiveHourRemaining = 100
      next.hasCapacity = true
      next.observedAt = ISO8601DateFormatter().string(from: .now)
      return next
    }
  }

  private func output(_ value: some Encodable) -> String? {
    (try? JSONEncoder().encode(value)).map { #"{"output":"# + String(decoding: $0, as: UTF8.self) + "}" }
  }
}
#endif
