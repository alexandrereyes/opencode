import Foundation
import Security

public enum WatchShared {
  /// Keychain access group shared by the watch app and its complication extension (`keychain-access-groups`,
  /// team prefix + this suffix). It needs no developer-portal capability, unlike an App Group.
  public static let keychainGroup = "ERRYZ68LX5.br.com.alexandrem.opencode.watch"
  public static let widgetKind = "br.com.alexandrem.opencode.watch.agents"
}

/// Small items in the watch's Keychain, readable by the app and the complication. Never synchronized to iCloud
/// and readable after the first unlock, so the complication refreshes while the watch is locked on the wrist.
public struct WatchKeychainStore: Sendable {
  private let service: String
  private let accessGroup: String?

  public init(service: String = "br.com.alexandrem.opencode.watch", accessGroup: String? = WatchShared.keychainGroup) {
    self.service = service
    self.accessGroup = accessGroup
  }

  private func query(_ account: String, group: Bool) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
    ]
    if group, let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    return query
  }

  public func read(_ account: String) throws -> Data? {
    do {
      return try read(account, group: true)
    } catch let failure as KeychainFailure where failure.status == errSecMissingEntitlement {
      // Unsigned simulator builds carry no entitlements: use the app's own default group.
      return try read(account, group: false)
    }
  }

  public func write(_ data: Data?, account: String) throws {
    do {
      try write(data, account: account, group: true)
    } catch let failure as KeychainFailure where failure.status == errSecMissingEntitlement {
      try write(data, account: account, group: false)
    }
  }

  private func read(_ account: String, group: Bool) throws -> Data? {
    var query = query(account, group: group)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    return result as? Data
  }

  private func write(_ data: Data?, account: String, group: Bool) throws {
    let query = query(account, group: group)
    guard let data else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainFailure(status: added) }
      return
    }
    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
  }
}

/// The pairing lives only in the watch's Keychain; the iPhone keeps nothing.
public struct WatchKeychain: Sendable {
  private let store: WatchKeychainStore
  public init(store: WatchKeychainStore = WatchKeychainStore()) { self.store = store }

  public func read() throws -> WatchPairing? {
    try store.read("pairing").flatMap { try? JSONDecoder().decode(WatchPairing.self, from: $0) }
  }

  public func write(_ pairing: WatchPairing?) throws {
    try store.write(pairing.map { try JSONEncoder().encode($0) }, account: "pairing")
  }
}

/// Last good gateway state, shared by the app and the complication through the same Keychain group (a few KB).
public struct WatchStateCache: Sendable {
  public struct Entry: Codable, Hashable, Sendable {
    public var snapshot: WatchStateSnapshot
    /// Epoch milliseconds of the successful fetch.
    public var fetchedAt: Double
    public var fetched: Date { Date(timeIntervalSince1970: fetchedAt / 1000) }
    public init(snapshot: WatchStateSnapshot, fetched: Date) {
      self.snapshot = snapshot
      fetchedAt = (fetched.timeIntervalSince1970 * 1000).rounded()
    }
  }

  private let store: WatchKeychainStore
  public init(store: WatchKeychainStore = WatchKeychainStore()) { self.store = store }

  public func read() -> Entry? {
    (try? store.read("state")).flatMap { $0 }.flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
  }

  public func write(_ entry: Entry?) {
    try? store.write(entry.flatMap { try? JSONEncoder().encode($0) }, account: "state")
  }
}

// MARK: iPhone side: `custom.watch` RPC

public extension OpenCodeClient {
  func watchPair(deviceName: String) async throws -> WatchPairing {
    struct Input: Encodable { let deviceName: String }
    return try await rpc("custom.watch", "pair", input: Input(deviceName: deviceName), timeout: 15)
  }

  func watchDevices() async throws -> [WatchDevice] {
    // The contract names the method without fixing the envelope; accept a bare list or `{ devices }`.
    let value: JSONValue = try await rpc("custom.watch", "devices", input: Empty(), timeout: 10)
    if let list = try? value.decoded(as: [WatchDevice].self) { return list }
    struct Output: Decodable { let devices: [WatchDevice] }
    return try value.decoded(as: Output.self).devices
  }

  func watchRevoke(deviceID: String) async throws {
    struct Input: Encodable { let deviceID: String }
    let _: JSONValue = try await rpc("custom.watch", "revoke", input: Input(deviceID: deviceID), timeout: 10)
  }
}
