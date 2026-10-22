import Foundation

public enum PairingError: LocalizedError {
  case invalid, expired, unreachable
  public var errorDescription: String? {
    switch self {
    case .invalid: "Este QR code ou link não é um pareamento do OpenCode."
    case .expired: "O código expirou ou já foi usado. Gere outro com opencode pair."
    case .unreachable: "Nenhum endereço do servidor respondeu. Confira a rede e tente novamente."
    }
  }
}

public struct PairingLink: Sendable, Equatable {
  public let code: String
  public let urls: [URL]

  public init(_ value: String) throws {
    struct Payload: Decodable { let code: String; let urls: [String] }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let payload: Payload
    if trimmed.hasPrefix("{") {
      guard let decoded = try? JSONDecoder().decode(Payload.self, from: Data(trimmed.utf8)) else {
        throw PairingError.invalid
      }
      payload = decoded
    } else {
      guard let parts = URLComponents(string: trimmed), ["http", "https"].contains(parts.scheme),
        let range = parts.path.range(of: "/auth/connect/"), range.lowerBound == parts.path.startIndex,
        parts.user == nil, parts.password == nil
      else { throw PairingError.invalid }
      var origin = parts
      origin.path = ""; origin.query = nil; origin.fragment = nil
      guard let address = origin.string else { throw PairingError.invalid }
      payload = Payload(code: String(parts.path[range.upperBound...]), urls: [address])
    }
    guard !payload.code.isEmpty,
      payload.code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
        || (48...57).contains($0) || $0 == 45 || $0 == 95 }), !payload.urls.isEmpty
    else { throw PairingError.invalid }
    let addresses = payload.urls.compactMap(ServerAddress.parse)
    guard addresses.count == payload.urls.count else { throw PairingError.invalid }
    code = payload.code
    urls = addresses.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
  }
}

public struct PairingResponse: Sendable {
  public let status: Int
  public let data: Data
  public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public struct PairingClient: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> PairingResponse
  private let transport: Transport

  public init(transport: Transport? = nil) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    self.transport = transport ?? { request in
      let (data, response) = try await session.data(for: request)
      return PairingResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
  }

  public func test(_ configuration: ServerConfiguration) async throws -> ServerInfo {
    var request = URLRequest(url: configuration.url.appendingPathComponent("api/info"))
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let password = configuration.password, !password.isEmpty {
      request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    }
    let response = try await transport(request)
    guard (200..<300).contains(response.status) else {
      if response.status == 401 { throw ClientError.http(401) }
      throw PairingError.unreachable
    }
    let info = try JSONDecoder().decode(ServerInfo.self, from: response.data)
    guard info.version?.isEmpty == false else { throw ClientError.incompatibleServer }
    return info
  }

  private struct Attempt: Sendable {
    let index: Int
    let token: String?
    let unauthorized: Bool
  }
  private enum Event: Sendable { case attempt(Attempt), deadline }

  public func redeem(_ link: PairingLink) async throws -> ServerConfiguration {
    struct Token: Decodable { let token: String }
    let (stream, continuation) = AsyncStream<Event>.makeStream()
    let attempts = link.urls.enumerated().map { index, url in
      Task {
        var request = URLRequest(url: url.appendingPathComponent("auth/connect/\(link.code)"))
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try? await transport(request)
        let token = response.flatMap {
          (200..<300).contains($0.status) ? try? JSONDecoder().decode(Token.self, from: $0.data).token : nil
        }
        continuation.yield(.attempt(Attempt(index: index, token: token?.isEmpty == false ? token : nil,
                                           unauthorized: response?.status == 401)))
      }
    }
    var deadline: Task<Void, Never>?
    defer {
      attempts.forEach { $0.cancel() }
      deadline?.cancel()
      continuation.finish()
    }
    var winner: Attempt?
    var first: Attempt?
    var completed = 0
    var expired = false
    for await event in stream {
      try Task.checkCancellation()
      if case .attempt(let attempt) = event {
        completed += 1
        expired = expired || attempt.unauthorized
        if attempt.index == 0 { first = attempt }
        if winner == nil, attempt.token != nil {
          winner = attempt
          // Match the web: give the preferred first URL one more second to answer.
          deadline = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            continuation.yield(.deadline)
          }
        }
      }
      if let winner, let token = winner.token {
        let configuration = ServerConfiguration(url: link.urls[winner.index], password: token)
        if winner.index == 0 { return configuration }
        if let first {
          let preferred = ServerConfiguration(url: link.urls[0], password: token)
          if (first.token != nil || first.unauthorized), (try? await test(preferred)) != nil {
            return preferred
          }
          return configuration
        }
        if case .deadline = event { return configuration }
      }
      if completed == link.urls.count { throw expired ? PairingError.expired : PairingError.unreachable }
    }
    throw CancellationError()
  }
}
