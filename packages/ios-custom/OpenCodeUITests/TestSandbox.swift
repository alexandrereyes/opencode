import Foundation

enum TestSandbox {
  static let url: String = {
    let value = ProcessInfo.processInfo.environment["OPENCODE_TEST_SERVER_URL"] ?? "http://127.0.0.1:4177"
    let url = URL(string: value)
    precondition(url?.scheme == "http" && ["127.0.0.1", "localhost"].contains(url?.host ?? "")
      && ![nil, 4096, 4178].contains(url?.port), "UI tests require an isolated loopback sandbox")
    return value
  }()
}
