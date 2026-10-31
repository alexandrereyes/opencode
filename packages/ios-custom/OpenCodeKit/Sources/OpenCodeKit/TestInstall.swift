#if DEBUG
import Foundation

/// An install only tests use: a DEBUG build on the iOS Simulator, or a Mac test copy (a bundle identifier of its
/// own). It never connects to a saved server or to the default (real) one, only to a loopback sandbox a test
/// passed. A launch without arguments (`XCUIApplication.activate()` after the app was closed, a relaunch by the
/// system, a reinstall) reuses the sandbox the last launch gave; with none, it connects nowhere.
@MainActor public enum TestInstall {
  static let urlKey = "OpenCodeTestInstall.sandbox"
  static let passwordAccount = "OpenCodeTestInstall.sandbox"

  /// What the install may connect to. `launch` is `ServerConfiguration.override()`: a sandbox there is remembered;
  /// anything else there (the UI proxy 4096, the backend 4178, a remote host) is refused, not remembered.
  public static func sandbox(launch: ServerConfiguration?, defaults: UserDefaults, credentials: ServerCredentials)
    -> ServerConfiguration?
  {
    if let launch {
      guard launch.isolatedTestSandbox else { return nil }
      defaults.set(launch.url.absoluteString, forKey: urlKey)
      try? credentials.set(launch.password, for: passwordAccount)
      return launch
    }
    guard let url = defaults.string(forKey: urlKey).flatMap(URL.init(string:)) else { return nil }
    let remembered = ServerConfiguration(url: url, password: try? credentials.password(passwordAccount))
    return remembered.isolatedTestSandbox ? remembered : nil
  }
}
#endif
