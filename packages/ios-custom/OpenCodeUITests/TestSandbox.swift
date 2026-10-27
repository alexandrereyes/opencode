import XCTest

enum TestSandbox {
  static let url: String = {
    let value = ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177"
    let url = URL(string: value)
    precondition(url?.scheme == "http" && ["127.0.0.1", "localhost"].contains(url?.host ?? "")
      && ![nil, 4096, 4178].contains(url?.port), "UI tests require an isolated loopback sandbox")
    return value
  }()
}

@MainActor extension XCUIApplication {
  /// Call before archiving or deleting: a simulator can reopen the app without the test's launch arguments, and it
  /// then connects to the default (real) server. Throws, ending the test without acting, unless it uses the sandbox.
  func requireSandbox() throws {
    let marker = staticTexts["debug-server-url"]
    guard marker.waitForExistence(timeout: 10) else {
      throw SandboxNotConfirmed(description: "O app não informou o servidor; nada será arquivado ou excluído.")
    }
    let connected = URL(string: marker.label)
    let expected = URL(string: TestSandbox.url)
    guard connected?.host == expected?.host, connected?.port == expected?.port else {
      throw SandboxNotConfirmed(
        description: "O app está em \(marker.label), não no sandbox \(TestSandbox.url); nada será arquivado ou excluído.")
    }
  }
}

struct SandboxNotConfirmed: Error, CustomStringConvertible {
  let description: String
}
