import Foundation
import Observation

public struct SubscriptionClock: Sendable {
  public let now: @Sendable () -> Date
  public let sleep: @Sendable (Duration) async throws -> Void
  public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.now = now; self.sleep = sleep
  }
  public static let live = Self(now: { .now }, sleep: { try await Task.sleep(for: $0) })
}

@MainActor public final class SubscriptionSelection {
  private let defaults: UserDefaults
  private let server: String
  private let key = "OpenCodeSubscriptionSelection.v1"
  public init(server: String, defaults: UserDefaults = .standard) { self.server = server; self.defaults = defaults }
  public func selected(_ provider: SubscriptionProvider) -> String? {
    defaults.dictionary(forKey: key)?[server + ":" + provider.rawValue] as? String
  }
  public func toggle(_ id: String, provider: SubscriptionProvider) {
    var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    values[server + ":" + provider.rawValue] = selected(provider) == id ? nil : id
    defaults.set(values, forKey: key)
  }
  public func reconcile(_ ids: Set<String>, provider: SubscriptionProvider) {
    guard let id = selected(provider), !ids.contains(id) else { return }
    toggle(id, provider: provider)
  }
}

public enum SubscriptionActionFailure: Error, LocalizedError, Sendable, Equatable {
  case noCredit, busy, consumeFailed, updateFailed, unsupported
  public var errorDescription: String? {
    switch self {
    case .noCredit: "Esta conta não tem redefinições disponíveis."
    case .busy: "Já existe uma redefinição em andamento nesta conta. Aguarde e atualize."
    case .consumeFailed: "Não foi possível confirmar a redefinição. Atualize antes de tentar novamente; ela pode ter sido consumida."
    case .updateFailed: "Não foi possível alterar a redefinição automática."
    case .unsupported: "Este servidor não oferece esta operação de LLM proxy. Atualize o servidor."
    }
  }
  public static func classify(_ error: any Error, automation: Bool) -> Self {
    if case ClientError.rpc(let type) = error {
      switch type {
      case "no_credit": return .noCredit
      case "busy": return .busy
      case "rpc.unavailable", "rpc.method_not_found", "rpc.invalid_input": return .unsupported
      default: break
      }
    }
    return automation ? .updateFailed : .consumeFailed
  }
}

@MainActor @Observable public final class SubscriptionStore {
  public enum Confirmation: Identifiable, Sendable {
    case automation(SubscriptionProvider, Bool)
    case reset(SubscriptionProvider, Subscriptions.Account)
    public var id: String {
      switch self {
      case .automation(let provider, _): "automation:" + provider.rawValue
      case .reset(let provider, let account): provider.rawValue + ":" + account.id
      }
    }
  }
  public struct Feedback: Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let failure: Bool
  }
  public private(set) var snapshot: Subscriptions?
  public private(set) var loading = false
  public private(set) var now: Date
  public private(set) var readError: String?
  public var confirmation: Confirmation?
  public private(set) var pending: [SubscriptionProvider: Bool] = [:]
  public private(set) var resetting: Set<String> = []
  public private(set) var feedback: Feedback?
  public private(set) var selectedIDs: [SubscriptionProvider: String] = [:]
  @ObservationIgnored private let client: any SubscriptionClient
  @ObservationIgnored private let clock: SubscriptionClock
  @ObservationIgnored private let selection: SubscriptionSelection
  @ObservationIgnored private var updated: Date?
  @ObservationIgnored private var request: Task<Void, Never>?
  @ObservationIgnored private var polling: Task<Void, Never>?
  @ObservationIgnored private var actions: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = UUID()

  public init(server: String, client: any SubscriptionClient, defaults: UserDefaults = .standard, clock: SubscriptionClock = .live) {
    self.client = client
    self.clock = clock
    self.selection = SubscriptionSelection(server: server, defaults: defaults)
    now = clock.now()
    selectedIDs = Dictionary(uniqueKeysWithValues: SubscriptionProvider.allCases.compactMap { provider in
      selection.selected(provider).map { (provider, $0) }
    })
  }
  public var providers: [SubscriptionProvider] {
    snapshot?.anthropic.status == "disabled" ? [.codex] : [.codex, .anthropic]
  }
  public func projection(_ provider: SubscriptionProvider, compact: Bool = false) -> SubscriptionProjection {
    let accounts = snapshot?.pool(provider).accounts ?? []
    let account = compact ? selected(provider) : nil
    return SubscriptionProjection(accounts: account.map { [$0] } ?? accounts, plan: account?.plan ?? provider.plan, now: now)
  }
  public func selected(_ provider: SubscriptionProvider) -> Subscriptions.Account? {
    snapshot?.pool(provider).accounts.first { $0.id == selectedIDs[provider] }
  }
  public func toggleSelection(_ account: Subscriptions.Account, provider: SubscriptionProvider) {
    selection.toggle(account.id, provider: provider)
    selectedIDs[provider] = selection.selected(provider)
  }
  public func summary(_ provider: SubscriptionProvider) -> Subscriptions.Summary? {
    guard let snapshot else { return nil }
    let projection = projection(provider, compact: true)
    return .init(remaining: snapshot.pool(provider).status == "ok" ? projection.remaining : nil,
                 reset: selected(provider).flatMap { Subscriptions.date($0.resetAt) } ?? projection.renewal,
                 ready: snapshot.pool(provider).status == "ok" && projection.ready > 0)
  }
  public func start() {
    guard polling == nil else { return }
    polling = Task {
      await refresh()
      while !Task.isCancelled {
        do { try await clock.sleep(.seconds(60)) } catch { break }
        guard !Task.isCancelled else { break }
        await refresh()
      }
    }
  }
  public func stop() async {
    generation = UUID()
    confirmation = nil
    let tasks = Array(actions.values) + [polling, request].compactMap { $0 }
    tasks.forEach { $0.cancel() }
    polling = nil
    request = nil
    actions = [:]
    pending = [:]
    resetting = []
    loading = false
    for task in tasks { await task.value }
  }
  public func refresh(ifDue: Bool = false) async {
    guard !Task.isCancelled else { return }
    guard let task = beginRefresh(ifDue: ifDue) else { return }
    await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }
  public func reconnect() { _ = beginRefresh(ifDue: false) }
  private func beginRefresh(ifDue: Bool) -> Task<Void, Never>? {
    if let request { return request }
    if ifDue, let updated, clock.now().timeIntervalSince(updated) < 60 { return nil }
    let generation = generation
    now = clock.now()
    loading = true
    let task = Task {
      defer { if self.generation == generation { loading = false; request = nil } }
      do {
        let value = try await client.subscriptions()
        guard !Task.isCancelled, self.generation == generation else { return }
        snapshot = value
        readError = nil
        for provider in SubscriptionProvider.allCases where value.pool(provider).status == "ok" {
          selection.reconcile(Set(value.pool(provider).accounts.map(\.id)), provider: provider)
          selectedIDs[provider] = selection.selected(provider)
        }
      } catch {
        guard !Task.isCancelled, self.generation == generation else { return }
        snapshot = .unavailable
        readError = "Não foi possível consultar o LLM proxy. Verifique a conexão e o suporte do servidor."
      }
      if self.generation == generation { updated = clock.now(); now = clock.now() }
    }
    request = task
    return task
  }
  public func requestAutomation(_ provider: SubscriptionProvider, enabled: Bool) {
    guard pending[provider] == nil, snapshot?.pool(provider).automation != nil else { return }
    confirmation = .automation(provider, enabled)
  }
  public func requestReset(_ provider: SubscriptionProvider, account: Subscriptions.Account) {
    guard (account.bankedResets?.available ?? 0) > 0, !resetting.contains(provider.rawValue + ":" + account.id) else { return }
    confirmation = .reset(provider, account)
  }
  public func confirm() async {
    guard let confirmation else { return }
    self.confirmation = nil
    let generation = generation
    let key = confirmation.id
    guard actions[key] == nil else { return }
    let task = Task {
      defer {
        if self.generation == generation {
          actions[key] = nil
          if case .automation(let provider, _) = confirmation { pending[provider] = nil }
          resetting.remove(key)
        }
      }
      switch confirmation {
      case .automation(let provider, let enabled):
        pending[provider] = enabled
        do {
          let value = try await client.setSubscriptionAutomation(provider, enabled: enabled)
          guard !Task.isCancelled, self.generation == generation else { return }
          if provider == .codex { snapshot?.automation = value }
          if provider == .anthropic { snapshot?.anthropic.automation = value }
          feedback = Feedback(text: value.enabled ? "Redefinição automática ativada." : "Redefinição automática pausada.", failure: false)
        } catch {
          guard !Task.isCancelled, self.generation == generation else { return }
          feedback = Feedback(text: SubscriptionActionFailure.classify(error, automation: true).localizedDescription, failure: true)
        }
      case .reset(let provider, let account):
        resetting.insert(key)
        do {
          _ = try await client.consumeSubscriptionReset(provider, accountID: account.id)
          guard !Task.isCancelled, self.generation == generation else { return }
          feedback = Feedback(text: "Redefinição aplicada a \(account.name).", failure: false)
        } catch {
          guard !Task.isCancelled, self.generation == generation else { return }
          feedback = Feedback(text: SubscriptionActionFailure.classify(error, automation: false).localizedDescription, failure: true)
        }
      }
      guard !Task.isCancelled, self.generation == generation else { return }
      // A poll begun before the mutation is not evidence of its resulting state.
      if let request { await request.value }
      guard !Task.isCancelled, self.generation == generation else { return }
      await refresh()
    }
    actions[key] = task
    await task.value
  }
}
