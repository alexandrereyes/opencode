#if DEBUG
import Foundation

extension ServerConfiguration {
  /// A loopback sandbox, never the production backend (4178) or UI proxy (4096). Agents run
  /// sandboxes on their own ports, so DEBUG failure fixtures must not require 4177/4183.
  public var isolatedTestSandbox: Bool {
    url.scheme == "http" && url.host == "127.0.0.1" && url.port.map { ![4096, 4178].contains($0) } == true
  }
}

extension OpenCodeClient {
  public static func composerSubmissionFailure(configuration: ServerConfiguration, sessionID: String) -> Self {
    precondition(configuration.isolatedTestSandbox)
    return Self(configuration: configuration) { request in
      if request.httpMethod == "POST", request.url?.path == "/api/session/\(sessionID)/prompt" {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
      }
      return try await URLSession.shared.data(for: request)
    }
  }

  /// A server without `custom.quotes` (before `custom:update`): its RPCs answer `rpc.method_not_found`.
  /// Other requests go through `inner`, so it combines with the other failure fixtures.
  public static func quotesUnavailableFixture(configuration: ServerConfiguration, inner: OpenCodeClient) -> Self {
    precondition(configuration.isolatedTestSandbox)
    return Self(configuration: configuration) { request in
      guard request.url?.path.hasPrefix("/api/rpc/custom.quotes/") == true else {
        let data = try await inner.data(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      }
      let body = Data(#"{"_tag":"RpcError","type":"rpc.method_not_found","message":"Unknown RPC"}"#.utf8)
      return (body, HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
    }
  }

  /// Delays one Session's prompt admission, then rejects it or admits it without waking
  /// execution, so optimistic-send checks need no model call. `*` matches every Session's prompt;
  /// `create` targets new-session creation instead. Sandbox-only.
  public static func promptAdmissionFixture(
    configuration: ServerConfiguration, sessionID: String, delay: Duration, fail: Bool
  ) -> Self {
    precondition(configuration.isolatedTestSandbox)
    return Self(configuration: configuration) { request in
      let path = request.url?.path ?? ""
      let matches = sessionID == "create" ? path == "/api/session"
        : sessionID == "*" ? path.hasPrefix("/api/session/") && path.hasSuffix("/prompt")
        : path == "/api/session/\(sessionID)/prompt"
      guard request.httpMethod == "POST", matches else {
        return try await URLSession.shared.data(for: request)
      }
      try await Task.sleep(for: delay)
      if fail {
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
      }
      var admitted = request
      var body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody ?? Data("{}".utf8))
      body["resume"] = .bool(false)
      admitted.httpBody = try JSONEncoder().encode(body)
      return try await URLSession.shared.data(for: admitted)
    }
  }
}
#endif
