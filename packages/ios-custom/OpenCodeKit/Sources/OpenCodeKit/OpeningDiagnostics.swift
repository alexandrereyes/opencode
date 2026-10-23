#if DEBUG
import Foundation

enum OpeningDiagnostics {
  static func delay(_ request: URLRequest) async throws {
    guard request.url?.host == "127.0.0.1",
      let value = ProcessInfo.processInfo.environment["OPENCODE_OPENING_DELAY_MS"],
      let milliseconds = Int(value), milliseconds > 0 else { return }
    try await Task.sleep(for: .milliseconds(milliseconds))
    if request.url?.path == "/api/rpc/custom.transcript/list",
      ProcessInfo.processInfo.environment["OPENCODE_OPENING_OLD_SERVER"] == "1" {
      throw ClientError.rpc("rpc.unavailable")
    }
  }

  static func record(_ kind: String, started: ContinuousClock.Instant, bytes: Int) {
    guard ProcessInfo.processInfo.environment["OPENCODE_OPENING_TRACE"] == "1" else { return }
    let elapsed = started.duration(to: .now).components
    let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    print("OPENING_\(kind) ms=\(ms) bytes=\(bytes)")
  }
}
#endif
