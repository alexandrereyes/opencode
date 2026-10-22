import Foundation
import Observation

public enum ServerAddress {
  public static func parse(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      var parts = URLComponents(string: trimmed.contains("://") ? trimmed : "http://" + trimmed),
      ["http", "https"].contains(parts.scheme), let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
    else { return nil }
    parts.scheme = parts.scheme?.lowercased()
    parts.host = host.lowercased()
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    return parts.url
  }
}

public struct SavedServer: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public var name: String
  public var url: URL
  public var title: String { name.isEmpty ? (url.host() ?? url.absoluteString) : name }
  public var builtIn: Bool { id == "builtin" }
}

public enum ServerStoreError: LocalizedError {
  case invalidAddress, builtIn, missing, sandboxOnly
  public var errorDescription: String? {
    switch self {
    case .invalidAddress: "Informe um endereço HTTP ou HTTPS sem senha, consulta ou fragmento."
    case .builtIn: "O servidor padrão não pode ser removido nem ter seu endereço alterado."
    case .missing: "O servidor não está mais salvo."
    case .sandboxOnly: "Esta execução de teste aceita apenas servidores de loopback."
    }
  }
}

@MainActor @Observable public final class ServerStore {
  public private(set) var servers: [SavedServer]
  public private(set) var activeID = "builtin"
  public private(set) var revision = 0
  public let launchOverride: ServerConfiguration?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let credentials: ServerCredentials
  @ObservationIgnored private let storageKey: String

  public init(defaults: UserDefaults = .standard, credentials: ServerCredentials = .init(),
              launchOverride: ServerConfiguration? = nil) {
    self.defaults = defaults
    self.credentials = credentials
    self.launchOverride = launchOverride
    // Explicit test servers never read or overwrite the installed app's server registry.
    storageKey = "OpenCodeServers" + (launchOverride.map { "." + $0.url.absoluteString } ?? "")
    let saved = defaults.data(forKey: storageKey).flatMap {
      try? JSONDecoder().decode([SavedServer].self, from: $0)
    } ?? []
    servers = [SavedServer(id: "builtin", name: defaults.string(forKey: storageKey + ".builtinName") ?? (launchOverride == nil ? "Mac de Alexandre" : "Sandbox (inicialização)"),
                           url: launchOverride?.url ?? ServerConfiguration.defaultURL)]
      + saved.filter { !$0.builtIn && ServerAddress.parse($0.url.absoluteString) != nil }
    let selected = defaults.string(forKey: storageKey + ".active") ?? "builtin"
    activeID = launchOverride == nil && servers.contains(where: { $0.id == selected }) ? selected : "builtin"
  }
  public var active: SavedServer { servers.first { $0.id == activeID }! }
  public func configuration() throws -> ServerConfiguration {
    if active.builtIn, let launchOverride { return launchOverride }
    try validate(active.url)
    return ServerConfiguration(url: active.url, password: try credentials.password(account(activeID)))
  }
  public func password(_ server: SavedServer) throws -> String? {
    if server.builtIn, let launchOverride { return launchOverride.password }
    return try credentials.password(account(server.id))
  }
  @discardableResult public func add(name: String, address: String, password: String?) throws -> SavedServer {
    guard let url = ServerAddress.parse(address) else { throw ServerStoreError.invalidAddress }
    try validate(url)
    let server = SavedServer(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
    try credentials.set(password, for: account(server.id))
    servers.append(server)
    persist()
    return server
  }
  public func edit(_ id: String, name: String, address: String, password: String?) throws {
    guard let index = servers.firstIndex(where: { $0.id == id }) else { throw ServerStoreError.missing }
    guard let url = ServerAddress.parse(address) else { throw ServerStoreError.invalidAddress }
    guard !servers[index].builtIn || url == servers[index].url else { throw ServerStoreError.builtIn }
    try validate(url)
    try credentials.set(password, for: account(id))
    servers[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    servers[index].url = url
    if activeID == id { revision += 1 }
    persist()
  }
  public func remove(_ id: String) throws {
    guard let server = servers.first(where: { $0.id == id }) else { throw ServerStoreError.missing }
    guard !server.builtIn else { throw ServerStoreError.builtIn }
    try credentials.set(nil, for: account(id))
    servers.removeAll { $0.id == id }
    if activeID == id { activeID = "builtin"; revision += 1 }
    persist()
  }
  public func select(_ id: String) throws {
    guard let server = servers.first(where: { $0.id == id }) else { throw ServerStoreError.missing }
    try validate(server.url)
    guard id != activeID else { return }
    // Fail before changing selection if Keychain is unavailable.
    _ = try password(server)
    activeID = id
    revision += 1
    persist()
  }
  public func validate(_ url: URL) throws {
    if let launchOverride, ["127.0.0.1", "localhost", "::1"].contains(launchOverride.url.host()),
       !["127.0.0.1", "localhost", "::1"].contains(url.host()) {
      throw ServerStoreError.sandboxOnly
    }
  }
  private func account(_ id: String) -> String { storageKey + "." + id }
  private func persist() {
    defaults.set(try? JSONEncoder().encode(servers.filter { !$0.builtIn }), forKey: storageKey)
    defaults.set(servers.first?.name, forKey: storageKey + ".builtinName")
    defaults.set(activeID, forKey: storageKey + ".active")
  }
}
