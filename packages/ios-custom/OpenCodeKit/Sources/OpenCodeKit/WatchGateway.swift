import Foundation

/// HTTP client of the watch gateway (`/watch/v1`). High-level `URLSession` only, so it also runs in the widget
/// extension and needs no audio session on watchOS (TN3135).
public struct WatchGatewayClient: Sendable {
  public let pairing: WatchPairing
  private let session: URLSession
  private let userAgent: String

  public init(pairing: WatchPairing, session: URLSession = WatchGatewayClient.makeSession(), version: String = "1") {
    self.pairing = pairing
    self.session = session
    // Cloudflare rejects some default agents with error 1010; the contract fixes a non-default one.
    userAgent = "OpenCodeWatch/\(version)"
  }

  public static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 40
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }

  public func ping() async throws -> WatchPing { try await send("GET", "ping", timeout: 8) }

  public func state() async throws -> WatchStateSnapshot { try await send("GET", "state", timeout: 15) }

  public func request(_ requestID: String) async throws -> WatchRequest {
    try await send("GET", "requests/\(Self.escape(requestID))", timeout: 15)
  }

  public func reply(_ requestID: String, _ reply: WatchReply) async throws {
    let _: OK = try await send("POST", "requests/\(Self.escape(requestID))/reply", body: reply, timeout: 15)
  }

  public func widgetToken(_ token: Data, environment: PushEnvironment) async throws {
    struct Body: Encodable {
      let token: String
      let environment: PushEnvironment
    }
    let _: OK = try await send("POST", "widget-token", body: Body(token: token.hexToken, environment: environment),
      timeout: 15)
  }

  public func startCall(sdp: String, voiceID: String?) async throws -> WatchVoiceCall {
    struct Body: Encodable {
      let sdp: String
      let voiceID: String?
    }
    return try await send("POST", "voice/calls", body: Body(sdp: sdp, voiceID: voiceID), timeout: 25)
  }

  public func heartbeat(_ callID: String, sent: Int, received: Int) async throws {
    struct Body: Encodable {
      let sent: Int
      let received: Int
    }
    let _: OK = try await send("POST", "voice/calls/\(Self.escape(callID))/heartbeat",
      body: Body(sent: sent, received: received), timeout: 8)
  }

  /// Long poll (the gateway answers within 25 s).
  public func events(_ callID: String, after: Int) async throws -> WatchVoiceEvents {
    try await send("GET", "voice/calls/\(Self.escape(callID))/events",
      query: [URLQueryItem(name: "after", value: String(after))], timeout: 35)
  }

  public func endCall(_ callID: String) async throws {
    let _: OK = try await send("DELETE", "voice/calls/\(Self.escape(callID))", timeout: 8)
  }

  public func diagnostics(_ events: [[String: String]]) async throws {
    struct Body: Encodable { let events: [[String: String]] }
    let _: OK = try await send("POST", "diagnostics", body: Body(events: Array(events.prefix(50))), timeout: 10)
  }

  // MARK: Transport

  private struct OK: Decodable {}
  private struct ErrorBody: Decodable {
    struct Detail: Decodable {
      let code: String
      let message: String
    }
    let error: Detail
  }

  private func send<Output: Decodable, Body: Encodable>(
    _ method: String, _ path: String, query: [URLQueryItem] = [], body: Body, timeout: TimeInterval
  ) async throws -> Output {
    try await perform(method, path, query: query, body: try JSONEncoder().encode(body), timeout: timeout)
  }

  private func send<Output: Decodable>(
    _ method: String, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval
  ) async throws -> Output {
    try await perform(method, path, query: query, body: nil, timeout: timeout)
  }

  private func perform<Output: Decodable>(
    _ method: String, _ path: String, query: [URLQueryItem], body: Data?, timeout: TimeInterval
  ) async throws -> Output {
    // Path components are already escaped here; `appending(path:)` would escape `%` again.
    guard var components = URLComponents(url: pairing.gatewayURL, resolvingAgainstBaseURL: false) else {
      throw WatchGatewayError.unreachable
    }
    let base = components.percentEncodedPath.hasSuffix("/")
      ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
    components.percentEncodedPath = base + "/watch/v1/" + path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else { throw WatchGatewayError.unreachable }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("Bearer \(pairing.deviceToken)", forHTTPHeaderField: "Authorization")
    request.setValue(pairing.access.clientId, forHTTPHeaderField: "CF-Access-Client-Id")
    request.setValue(pairing.access.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw WatchGatewayError.unreachable
    }
    guard let http = response as? HTTPURLResponse else { throw WatchGatewayError.unreachable }
    try Self.check(http, data: data)
    do {
      return try JSONDecoder().decode(Output.self, from: data)
    } catch {
      // Proxies answering 200 with an HTML page are not the gateway.
      throw Self.isJSON(http) ? error : WatchGatewayError.unreachable
    }
  }

  static func check(_ http: HTTPURLResponse, data: Data) throws {
    switch http.statusCode {
    case 200..<300: return
    case 401: throw WatchGatewayError.unauthorized
    case 404, 409: throw WatchGatewayError.gone
    case 429: throw WatchGatewayError.rateLimited
    default:
      // Cloudflare and the tunnel answer with HTML pages: the gateway itself is not there.
      guard isJSON(http), let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
        throw WatchGatewayError.unreachable
      }
      throw WatchGatewayError.server(status: http.statusCode, code: body.error.code, message: body.error.message)
    }
  }

  private static func isJSON(_ http: HTTPURLResponse) -> Bool {
    http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") == true
  }

  private static func escape(_ component: String) -> String {
    component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
      ?? component
  }
}
