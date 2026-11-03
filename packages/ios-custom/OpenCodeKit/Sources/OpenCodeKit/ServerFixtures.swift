#if DEBUG
import Foundation

/// Saved servers held in memory for the apps' fixtures (the Mac's `-OpenCodeMacServers`, the iPhone's
/// `-OpenCodeFixtureServers`): `ServerStore` reads and writes them through these, so the app's defaults and the
/// Keychain never see a fake server.
public final class InMemoryServerDefaults: UserDefaults, @unchecked Sendable {
  private var values: [String: Any] = [:]
  public convenience init(values: [String: Any]) {
    self.init(suiteName: nil)!
    self.values = values
  }
  public override func object(forKey defaultName: String) -> Any? { values[defaultName] }
  public override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
  public override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
  public override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
  public override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
}

/// No Keychain for the fake servers.
public final class InMemoryCredentials: CredentialBackend {
  private var values: [String: Data] = [:]
  public init() {}
  public func read(_ account: String) throws -> Data? { values[account] }
  public func write(_ data: Data?, account: String) throws { values[account] = data }
}

extension ServerStore {
  /// A store of fake servers: the default one named `builtinName`, then `servers` (ID, name, address), all in memory.
  public static func fixture(_ servers: [(String, String, String)], builtinName: String,
                             launchOverride: ServerConfiguration? = nil, builtinURL: URL = ServerConfiguration.defaultURL)
    -> ServerStore
  {
    let saved = servers.compactMap { id, name, address in
      ServerAddress.parse(address).map { SavedServer(id: id, name: name, url: $0) }
    }
    let key = "OpenCodeServers" + (launchOverride.map { "." + $0.url.absoluteString } ?? "")
    let defaults = InMemoryServerDefaults(values: [
      key: (try? JSONEncoder().encode(saved)) ?? Data("[]".utf8),
      key + ".builtinName": builtinName,
    ])
    return ServerStore(defaults: defaults, credentials: ServerCredentials(backend: InMemoryCredentials()),
      launchOverride: launchOverride, builtinURL: builtinURL)
  }
}
#endif
