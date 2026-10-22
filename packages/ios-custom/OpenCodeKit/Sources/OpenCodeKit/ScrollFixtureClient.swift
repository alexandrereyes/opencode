#if DEBUG
import Foundation

extension OpenCodeClient {
  /// Fixture UI is read-only. Even accidental actions cannot open an HTTP connection.
  public static func scrollFixture(configuration: ServerConfiguration) -> Self {
    Self(configuration: configuration) { _ in throw URLError(.notConnectedToInternet) }
  }
}
#endif
