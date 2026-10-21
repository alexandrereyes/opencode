import Foundation

public struct ServerConfiguration: Sendable {
  public let url: URL
  public let password: String?

  public init(url: URL, password: String? = nil) {
    self.url = url
    self.password = password
  }

  public static func launch(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    func value(_ key: String) -> String? {
      guard let index = arguments.firstIndex(of: "-\(key)"), arguments.indices.contains(index + 1)
      else {
        return environment[key]
          ?? environment[
            key == "OpenCodeServerURL" ? "OPENCODE_SERVER_URL" : "OPENCODE_SERVER_PASSWORD"]
      }
      return arguments[index + 1]
    }
    return Self(
      url: URL(string: value("OpenCodeServerURL") ?? "http://opencode2-mac.alexandrem.com.br")!,
      password: value("OpenCodeServerPassword"))
  }
}

public struct ServerInfo: Codable, Sendable { public let version: String }
public struct Empty: Codable, Sendable { public init() {} }

public struct OpenCodeClient: Sendable {
  public let configuration: ServerConfiguration
  private let session: URLSession

  public init(configuration: ServerConfiguration) {
    self.configuration = configuration
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 45
    config.timeoutIntervalForResource = 60 * 60
    session = URLSession(configuration: config)
  }

  public func info() async throws -> ServerInfo { try await get("/api/info") }
  public func projects() async throws -> [Project] { try await get("/api/project") }
  public func archivedSessions() async throws -> [Session] {
    struct Page: Decodable {
      let data: [Session]
      let cursor: Cursor
      struct Cursor: Decodable { let next: String? }
    }
    var cursor: String?
    var archived: [Session] = []
    repeat {
      let query =
        [URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "parentID", value: "null")]
        + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
      let page: Page = try await get("/api/session", query: query)
      archived.append(contentsOf: page.data.filter { $0.time.archived != nil })
      if page.data.isEmpty || page.cursor.next == cursor { break }
      cursor = page.cursor.next
    } while cursor != nil
    return archived
  }
  public func active() async throws -> [String: ActiveState] {
    let response: DataResponse<[String: ActiveState]> = try await get("/api/session/active")
    return response.data
  }
  public func preferences() async throws -> Preferences {
    try await rpc("custom.preferences", "get", input: Empty())
  }
  public func mutate(_ intent: PreferenceIntent) async throws -> Preferences {
    try await rpc("custom.preferences", "mutate", input: intent)
  }
  public func subscriptions() async throws -> Subscriptions {
    try await rpc("custom.subscriptions", "list", input: Empty())
  }
  public func navigation() async throws -> [NavigationEntry] {
    struct Input: Encodable {
      let limit = 500
      let after: String?
    }
    var after: String?
    var rows: [String: NavigationEntry] = [:]
    repeat {
      let page: NavigationPage = try await rpc(
        "custom.navigation", "list", input: Input(after: after))
      page.data.forEach { rows[$0.session.id] = $0 }
      if page.next == after { break }
      after = page.next
    } while after != nil
    return Array(rows.values)
  }
  public func chatRoot() async throws -> String {
    struct Response: Decodable { let root: String }
    let result: Response = try await rpc("custom.chats", "info", input: Empty())
    return result.root
  }
  public func locate(_ directories: [String]) async throws -> [LocatedDirectory] {
    struct Input: Encodable { let directories: [String] }
    return try await rpc("custom.worktrees", "locate", input: Input(directories: directories))
  }
  public func permissions() async throws -> [PermissionRequest] {
    try await rpc("custom.requests", "permissions", input: Empty())
  }
  public func forms(directory: String) async throws -> [PendingForm] {
    let response: DataResponse<[PendingForm]> = try await get(
      "/api/form", query: [URLQueryItem(name: "location[directory]", value: directory)])
    return response.data
  }
  public func family(_ sessionID: String) async throws -> FamilySnapshot {
    struct Input: Encodable { let sessionID: String }
    return try await rpc("custom.session-family", "snapshot", input: Input(sessionID: sessionID))
  }
  public func preview(_ sessionID: String) async throws -> SessionPreview {
    struct Input: Encodable {
      let sessionID: String
      let limit = 3
      let order = "desc"
    }
    let page: TranscriptPage = try await rpc(
      "custom.transcript", "list", input: Input(sessionID: sessionID))
    return SessionPreview(messages: page.data)
  }
  public func archive(_ sessionID: String) async throws {
    struct Input: Encodable { let sessionID: String }
    let _: Empty = try await rpc("custom.archive", "archive", input: Input(sessionID: sessionID))
  }
  public func markViewed(_ session: Session) async throws {
    guard let idle = session.time.idle, idle > (session.time.viewed ?? 0) else { return }
    struct Input: Encodable { let idle: Double }
    try await post("/api/session/\(session.id)/view", input: Input(idle: idle))
  }
  public func reply(_ permission: PermissionRequest, allow: Bool) async throws {
    struct Input: Encodable { let decision: String }
    try await post(
      "/api/session/\(permission.sessionID)/permission/\(permission.id)/reply",
      input: Input(decision: allow ? "once" : "reject"))
  }

  private struct RPCInput<Value: Encodable>: Encodable { let input: Value }
  private struct RPCOutput<Value: Decodable>: Decodable { let output: Value }

  public func rpc<Input: Encodable, Output: Decodable>(_ id: String, _ method: String, input: Input)
    async throws -> Output
  {
    var request = request("/api/rpc/\(id)/\(method)")
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(RPCInput(input: input))
    let data = try await data(request)
    return try JSONDecoder().decode(RPCOutput<Output>.self, from: data).output
  }
  private func get<Output: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws
    -> Output
  {
    try JSONDecoder().decode(Output.self, from: await data(request(path, query: query)))
  }
  private func post<Input: Encodable>(_ path: String, input: Input) async throws {
    var request = request(path)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(input)
    _ = try await data(request)
  }
  private func data(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    try validate(response)
    return data
  }
  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
  }
  private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
    var url = URLComponents(
      url: configuration.url.appending(path: path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { url.queryItems = query }
    var request = URLRequest(url: url.url!)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let password = configuration.password, !password.isEmpty {
      request.setValue(
        "Basic \(Data("opencode:\(password)".utf8).base64EncodedString())",
        forHTTPHeaderField: "Authorization")
    }
    return request
  }

  public func events() -> AsyncThrowingStream<ServerEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = request("/api/event")
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          // URLSession resets this idle timeout whenever bytes arrive, including heartbeat comments.
          request.timeoutInterval = 45
          let (bytes, response) = try await session.bytes(for: request)
          try validate(response)
          continuation.yield(.connected)
          var parser = EventParser()
          // AsyncBytes.lines omits empty lines, but SSE uses them to dispatch a frame.
          for try await byte in bytes {
            try Task.checkCancellation()
            if let event = parser.consume(byte) { continuation.yield(event) }
          }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

public enum ClientError: Error, LocalizedError {
  case http(Int)
  public var errorDescription: String? {
    switch self {
    case .http(401): "A senha do servidor não foi aceita."
    case .http(let code): "O servidor respondeu com o código \(code)."
    }
  }
}
