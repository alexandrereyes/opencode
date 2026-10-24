#if DEBUG
import Foundation

extension OpenCodeClient {
  public static func composerSubmissionFailure(configuration: ServerConfiguration, sessionID: String) -> Self {
    precondition(["http://127.0.0.1:4177", "http://127.0.0.1:4183"].contains(configuration.url.absoluteString))
    return Self(configuration: configuration) { request in
      if request.httpMethod == "POST", request.url?.path == "/api/session/\(sessionID)/prompt" {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
      }
      return try await URLSession.shared.data(for: request)
    }
  }
}
#endif
