#if DEBUG
import Foundation

extension OpenCodeClient {
  /// A closed in-memory transport: unknown requests fail instead of reaching a real server.
  public static func screenCatalog(configuration: ServerConfiguration, responses: [String: String]) -> Self {
    Self(configuration: configuration) { request in
      guard let url = request.url, let json = responses[url.path] else {
        throw URLError(.notConnectedToInternet)
      }
      return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
  }

  /// A closed in-memory transport that routes on the whole request (path, query and body); `nil` fails the
  /// request instead of reaching a real server.
  public static func inMemory(
    configuration: ServerConfiguration, respond: @escaping @Sendable (URLRequest) -> String?
  ) -> Self {
    Self(configuration: configuration) { request in
      guard let url = request.url, let json = respond(request) else { throw URLError(.notConnectedToInternet) }
      return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
  }
}
#endif
