import Foundation
import Testing
@testable import OpenCodeKit

@MainActor private final class Credentials: CredentialBackend {
  var values: [String: Data] = [:]
  func read(_ account: String) throws -> Data? { values[account] }
  func write(_ data: Data?, account: String) throws { values[account] = data }
}

@MainActor @Test func testInstallNeverFallsBackToSavedOrRealServers() throws {
  let suite = "test-install-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let credentials = ServerCredentials(backend: Credentials())
  // The installed app's registry, as a reinstall over a real install would find it.
  defaults.set(#"[{"id":"x","name":"Produção","url":"https://opencode2-mac.alexandrem.com.br"}]"#.data(using: .utf8),
    forKey: "OpenCodeServers")
  defaults.set("x", forKey: "OpenCodeServers.active")

  // Launched without arguments and without an earlier sandbox: nothing, and no server is reachable.
  #expect(TestInstall.sandbox(launch: nil, defaults: defaults, credentials: credentials) == nil)
  let blocked = ServerStore(defaults: defaults, credentials: credentials, launchOverride: nil, testWithoutSandbox: true)
  #expect(throws: ServerStoreError.self) { try blocked.configuration() }
  #expect(throws: ServerStoreError.self) { try blocked.select("x") }
  #expect(blocked.servers.map(\.id) == ["builtin"])

  // The production proxy, the backend or a remote host given at launch are refused and not remembered.
  for refused in ["http://127.0.0.1:4096", "http://127.0.0.1:4178", "http://opencode2-mac.alexandrem.com.br"] {
    let launch = ServerConfiguration(url: URL(string: refused)!, password: "real")
    #expect(TestInstall.sandbox(launch: launch, defaults: defaults, credentials: credentials) == nil, "\(refused)")
  }
  #expect(TestInstall.sandbox(launch: nil, defaults: defaults, credentials: credentials) == nil)

  // A sandbox given once is reused when the system or `activate()` relaunches the app without arguments.
  let sandbox = ServerConfiguration(url: URL(string: "http://127.0.0.1:4196")!, password: "sandbox-password")
  #expect(TestInstall.sandbox(launch: sandbox, defaults: defaults, credentials: credentials)?.url == sandbox.url)
  let relaunch = try #require(TestInstall.sandbox(launch: nil, defaults: defaults, credentials: credentials))
  #expect(relaunch.url == sandbox.url && relaunch.password == "sandbox-password")
  let store = ServerStore(defaults: defaults, credentials: credentials, launchOverride: relaunch)
  #expect(try store.configuration().url == sandbox.url)
  #expect(throws: ServerStoreError.self) { try store.add(name: "real", address: "opencode2-mac.alexandrem.com.br", password: nil) }
  #expect(ServerConfiguration(url: URL(string: "http://localhost:4196")!).isolatedTestSandbox)
}
