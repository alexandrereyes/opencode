import Foundation
import Testing

@testable import OpenCodeKit

@Test func bundledThemeFamiliesAndAppearanceResolution() throws {
  let registry = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("OpenCode/Resources/Themes/registry.json")
  let families = try ThemeFamily.registry(Data(contentsOf: registry))
  #expect(families.count == 38)
  #expect(Set(families.map(\.id)).count == 38)
  for family in families {
    #expect(family.dark == family.id + "-dark")
    #expect(family.light == family.id + "-light")
    for variant in [family.light, family.dark] {
      let theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf:
        registry.deletingLastPathComponent().appendingPathComponent(variant + ".json")))
      #expect(theme.id == variant)
    }
  }
  let system = ThemeSelection(family: nil, appearance: nil, arguments: [])
  #expect(system.resolve(systemDark: true) == "openchamber-dark")
  #expect(system.resolve(systemDark: false) == "openchamber-light")
  for dark in [true, false] {
    #expect(ThemeSelection(family: "dracula", appearance: "dark", arguments: []).resolve(systemDark: dark) == "dracula-dark")
    #expect(ThemeSelection(family: "dracula", appearance: "light", arguments: []).resolve(systemDark: dark) == "dracula-light")
    #expect(ThemeSelection(family: "dracula", appearance: "light", arguments: ["-OpenCodeTheme", "openchamber-dark"]).resolve(systemDark: dark) == "openchamber-dark")
  }
}

@Test func pairingParsesOnlyExactCodesAndAddresses() throws {
  let qr = try PairingLink(#"{"code":"abc-DEF_123","urls":["http://127.0.0.1:4177/","http://127.0.0.1:4177"]}"#)
  #expect(qr.urls == [URL(string: "http://127.0.0.1:4177")!])
  #expect(try PairingLink(" http://127.0.0.1:4177/auth/connect/abc-DEF_123 \n") == qr)
  for value in ["", "not a code", "file:///auth/connect/a", "http://x/auth/connect/", "http://x/auth/connect/a/b",
                "http://user:password@x/auth/connect/abc", #"{"code":"../a","urls":["http://x"]}"#,
                #"{"code":"a","urls":[]}"#, #"{"code":"a","urls":["http://x","file:///tmp"]}"#,
                #"{"code":"a","urls":["http://x?password=no"]}"#] {
    #expect(throws: PairingError.self) { try PairingLink(value) }
  }
  #expect(ServerAddress.parse(" localhost:4177/ ")?.absoluteString == "http://localhost:4177")
  #expect(ServerAddress.parse("https://x/path/")?.absoluteString == "https://x/path")
  #expect(ServerAddress.parse("http://x#secret") == nil)
}

private actor PairingProbe {
  var requests: [URLRequest] = []
  private var first: CheckedContinuation<PairingResponse, Never>?
  private var second: CheckedContinuation<Void, Never>?
  func respond(_ request: URLRequest) async -> PairingResponse {
    requests.append(request)
    if request.url?.path == "/api/info" {
      return PairingResponse(status: 200, data: Data(#"{"version":"test"}"#.utf8))
    }
    if request.url?.host == "first" {
      return await withCheckedContinuation { first = $0; second?.resume(); second = nil }
    }
    if first == nil { await withCheckedContinuation { second = $0 } }
    first?.resume(returning: PairingResponse(status: 401, data: Data()))
    first = nil
    return PairingResponse(status: 200, data: Data(#"{"token":"unit-test-token"}"#.utf8))
  }
}

@Test func pairingRacesAddressesAndPrefersFirstAfterUnauthorized() async throws {
  let probe = PairingProbe()
  let client = PairingClient { await probe.respond($0) }
  let paired = try await client.redeem(PairingLink(#"{"code":"a","urls":["http://first","http://second"]}"#))
  #expect(paired.url.host == "first")
  #expect(paired.password == "unit-test-token")
  let requests = await probe.requests
  #expect(requests.filter { $0.url?.path == "/auth/connect/a" }.count == 2)
  #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
  #expect(requests.filter { $0.url?.path == "/auth/connect/a" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
  #expect(requests.last?.url?.absoluteString == "http://first/api/info")
  #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:unit-test-token".utf8).base64EncodedString())
}

@Test func pairingFallsBackWhenPreferredHealthFailsAndClassifiesErrors() async throws {
  let client = PairingClient { request in
    if request.url?.host == "first" { return PairingResponse(status: 401, data: Data()) }
    return PairingResponse(status: 200, data: Data(#"{"token":"unit-test-token"}"#.utf8))
  }
  #expect(try await client.redeem(PairingLink(#"{"code":"a","urls":["http://first","http://second"]}"#)).url.host == "second")
  for status in [401, 503] {
    let unavailable = PairingClient { _ in PairingResponse(status: status, data: Data()) }
    do {
      _ = try await unavailable.redeem(PairingLink("http://first/auth/connect/a"))
      Issue.record("Expected failure")
    } catch let error as PairingError {
      switch error {
      case .expired: #expect(status == 401)
      case .unreachable: #expect(status == 503)
      default: Issue.record("Unexpected pairing error")
      }
    }
  }
}

@MainActor private final class MemoryCredentials: CredentialBackend {
  var values: [String: Data] = [:]
  var fail = false
  func read(_ account: String) throws -> Data? {
    if fail { throw KeychainFailure(status: -1) }
    return values[account]
  }
  func write(_ data: Data?, account: String) throws {
    if fail { throw KeychainFailure(status: -1) }
    values[account] = data
  }
}

@MainActor @Test func serverCRUDKeychainIsolationAndActiveSelection() throws {
  let suite = "settings-tests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let backend = MemoryCredentials()
  let credentials = ServerCredentials(backend: backend)
  let store = ServerStore(defaults: defaults, credentials: credentials)
  #expect(store.active.url == ServerConfiguration.defaultURL)
  #expect(throws: ServerStoreError.self) { try store.remove("builtin") }
  #expect(throws: ServerStoreError.self) { try store.edit("builtin", name: "x", address: "http://localhost:9", password: nil) }
  let server = try store.add(name: " Sandbox ", address: "http://localhost:4177/", password: "unit-test-password")
  #expect(server.name == "Sandbox")
  #expect(try store.password(server) == "unit-test-password")
  let serialized = try #require(defaults.data(forKey: "OpenCodeServers"))
  #expect(!String(decoding: serialized, as: UTF8.self).contains("unit-test-password"))
  try store.select(server.id)
  #expect(store.revision == 1)
  try store.select(server.id)
  #expect(store.revision == 1)
  #expect(try store.configuration().password == "unit-test-password")
  try store.edit(server.id, name: "Local", address: "http://localhost:9", password: "changed")
  #expect(store.revision == 2)
  let restored = ServerStore(defaults: defaults, credentials: credentials)
  #expect(restored.active.title == "Local")
  #expect(try restored.configuration().password == "changed")
  backend.fail = true
  #expect(throws: KeychainFailure.self) { try store.add(name: "fail", address: "http://localhost", password: "x") }
  #expect(store.servers.count == 2)
  backend.fail = false
  try store.remove(server.id)
  #expect(store.active.builtIn)
  #expect(backend.values.isEmpty)
  #expect(store.revision == 3)
  #expect(throws: ServerStoreError.self) { try store.select(server.id) }
}

@MainActor @Test func launchServerOverrideIsIsolatedAndNeverSelectsProduction() throws {
  let suite = "settings-tests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let credentials = ServerCredentials(backend: MemoryCredentials())
  let configuration = try #require(ServerConfiguration.override(arguments: ["-OpenCodeServerURL", "http://127.0.0.1:4177"], environment: ["OPENCODE_SERVER_PASSWORD": "launch-test"]))
  let store = ServerStore(defaults: defaults, credentials: credentials, launchOverride: configuration)
  #expect(try store.configuration().url == configuration.url)
  #expect(try store.configuration().password == "launch-test")
  #expect(throws: ServerStoreError.self) { try store.add(name: "forbidden", address: ServerConfiguration.defaultURL.absoluteString, password: nil) }
  let fake = try store.add(name: "Offline", address: "http://127.0.0.1:9", password: nil)
  try store.select(fake.id)
  #expect(try store.configuration().url.port == 9)
  let relaunched = ServerStore(defaults: defaults, credentials: credentials, launchOverride: configuration)
  #expect(relaunched.active.builtIn)
  #expect(try relaunched.configuration().url.port == 4177)
  #expect(defaults.data(forKey: "OpenCodeServers") == nil)
}

@Test func subagentPreambleIsExactAndOnlyAChildPresentation() {
  let prompt = "Confira o código.\nPreserve esta segunda linha."
  let raw = SubagentPreamble.prefix + prompt
  #expect(SubagentPreamble.stripping(raw, isChild: true) == prompt)
  #expect(SubagentPreamble.stripping(raw, isChild: false) == raw)
  for changed in [" " + raw, raw.replacingOccurrences(of: "session.", with: "session!"),
                  raw.replacingOccurrences(of: "session.\n", with: "session.\r\n"),
                  "Outra instrução\n" + raw, "You are a subagent spawned by another session."] {
    #expect(SubagentPreamble.stripping(changed, isChild: true) == changed)
  }
  var message = ConversationMessage(id: "unit", type: "user", time: MessageTime(created: 0))
  message.text = raw
  #expect(message.presented(isChild: true).displayText == prompt)
  #expect(message.presented(isChild: true).copyText == prompt)
  #expect(message.text == raw)
  message.metadata = ["displayText": .string("Texto autoral")]
  #expect(message.presented(isChild: true).copyText == "Texto autoral")
}

@MainActor @Test func credentialsSupportReplacementClearingAndReadFailures() throws {
  let backend = MemoryCredentials()
  let credentials = ServerCredentials(backend: backend)
  #expect(try credentials.password("server") == nil)
  try credentials.set("unit-test-first", for: "server")
  try credentials.set("unit-test-replaced", for: "server")
  #expect(try credentials.password("server") == "unit-test-replaced")
  #expect(backend.values.count == 1)
  backend.fail = true
  #expect(throws: KeychainFailure.self) { try credentials.password("server") }
  backend.fail = false
  try credentials.set("", for: "server")
  #expect(try credentials.password("server") == nil)
}

@Test func serverLaunchArgumentsBeatEnvironmentAndSavedConfiguration() throws {
  let config = try #require(ServerConfiguration.override(
    arguments: ["-OpenCodeServerURL", "http://127.0.0.1:4177", "-OpenCodeServerPassword", "argument-test"],
    environment: ["OPENCODE_SERVER_URL": "http://127.0.0.1:9", "OPENCODE_SERVER_PASSWORD": "environment-test"]))
  #expect(config.url.port == 4177)
  #expect(config.password == "argument-test")
  #expect(ServerConfiguration.override(arguments: [], environment: [:]) == nil)
  let passwordOnly = try #require(ServerConfiguration.override(arguments: [], environment: ["OPENCODE_SERVER_PASSWORD": "unit-test"]))
  #expect(passwordOnly.url == ServerConfiguration.defaultURL)
  #expect(passwordOnly.password == "unit-test")
}

@Test func connectionTestRequiresAuthenticatedCompatibleInfo() async throws {
  let client = PairingClient { request in
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/prefix/api/info")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    return PairingResponse(status: 200, data: Data(#"{"version":"sandbox-test"}"#.utf8))
  }
  #expect(try await client.test(.init(url: URL(string: "http://localhost/prefix")!)).version == "sandbox-test")
  for body in [#"{}"#, #"{"version":2}"#, #"{"version":""}"#] {
    let incompatible = PairingClient { _ in PairingResponse(status: 200, data: Data(body.utf8)) }
    await #expect(throws: ClientError.self) {
      try await incompatible.test(.init(url: URL(string: "http://localhost")!))
    }
  }
}
