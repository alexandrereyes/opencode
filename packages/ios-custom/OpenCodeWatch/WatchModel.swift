import Foundation
import Observation
import OpenCodeKit
import WidgetKit

/// The watch's single source of UI state: the pairing (Keychain), the last good gateway state (shared
/// Keychain group, read by the complication too) and whether the Mac answered the last refresh.
@MainActor @Observable final class WatchModel {
  enum Connection: Equatable {
    case unpaired
    case loading
    case online
    case unreachable
    /// The gateway rejected the device token: pair again from the iPhone.
    case unauthorized
  }

  private(set) var pairing: WatchPairing?
  private(set) var entry: WatchStateCache.Entry?
  private(set) var connection: Connection = .unpaired

  @ObservationIgnored private let keychain = WatchKeychain()
  @ObservationIgnored private let cache = WatchStateCache()
  @ObservationIgnored private var refreshing: Task<Void, Never>?
  @ObservationIgnored private var registeredToken: Data?
  @ObservationIgnored let fixture: Bool

  var state: AgentsState? { entry?.snapshot.state }
  var client: WatchGatewayClient? { pairing.map { WatchGatewayClient(pairing: $0, version: Self.version) } }

  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"

  init(fixture: WatchFixture? = WatchFixture.launch) {
    self.fixture = fixture != nil
    if let fixture {
      pairing = fixture.pairing
      entry = fixture.entry
      connection = fixture.connection
      return
    }
    pairing = try? keychain.read()
    entry = cache.read()
    connection = pairing == nil ? .unpaired : .loading
  }

  /// A pairing (or a re-sync of the same one) from the iPhone.
  func apply(_ pairing: WatchPairing) {
    guard pairing != self.pairing else { return }
    try? keychain.write(pairing)
    self.pairing = pairing
    registeredToken = nil
    connection = .loading
    refresh()
  }

  /// The iPhone removed this watch.
  func revoke(deviceID: String) {
    guard pairing?.deviceID == deviceID else { return }
    forget()
  }

  func refresh() {
    guard !fixture, let client else { return }
    refreshing?.cancel()
    refreshing = Task { await self.load(client) }
  }

  func refreshNow() async {
    guard !fixture, let client else { return }
    await load(client)
  }

  private func load(_ client: WatchGatewayClient) async {
    do {
      let snapshot = try await client.state()
      let changed = snapshot != entry?.snapshot
      let entry = WatchStateCache.Entry(snapshot: snapshot, fetched: Date())
      self.entry = entry
      cache.write(entry)
      connection = .online
      if changed { WidgetCenter.shared.reloadTimelines(ofKind: WatchShared.widgetKind) }
      await registerWidgetToken(client)
    } catch is CancellationError {
    } catch WatchGatewayError.unauthorized {
      forget()
      connection = .unauthorized
    } catch {
      connection = .unreachable
    }
  }

  /// The complication extension registers too (push handler); the app covers launches before any push.
  private func registerWidgetToken(_ client: WatchGatewayClient) async {
    guard let token = await Self.widgetPushToken(), token != registeredToken else { return }
    do {
      try await client.widgetToken(token, environment: WatchEnvironment.push)
      registeredToken = token
    } catch {}
  }

  nonisolated private static func widgetPushToken() async -> Data? {
    await WidgetCenter.shared.currentPushInfo?.token
  }

  private func forget() {
    try? keychain.write(nil)
    cache.write(nil)
    pairing = nil
    entry = nil
    connection = .unpaired
    WidgetCenter.shared.reloadTimelines(ofKind: WatchShared.widgetKind)
  }
}

enum WatchEnvironment {
  /// Development-signed builds (installed from Xcode) use the APNs sandbox; TestFlight builds production.
  static var push: PushEnvironment {
    #if targetEnvironment(simulator)
      PushEnvironment.resolve(profile: nil, simulator: true)
    #else
      PushEnvironment.resolve(
        profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
          .flatMap { try? Data(contentsOf: $0) }, simulator: false)
    #endif
  }
}
