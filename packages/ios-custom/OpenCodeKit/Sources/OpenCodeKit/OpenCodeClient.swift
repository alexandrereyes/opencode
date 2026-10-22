import Foundation

public struct ServerConfiguration: Sendable {
  public static let defaultURL = URL(string: "http://opencode2-mac.alexandrem.com.br")!

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
      url: URL(string: value("OpenCodeServerURL") ?? defaultURL.absoluteString)!,
      password: value("OpenCodeServerPassword"))
  }

  public static func override(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self? {
    guard arguments.contains("-OpenCodeServerURL") || environment["OpenCodeServerURL"] != nil
      || environment["OPENCODE_SERVER_URL"] != nil || arguments.contains("-OpenCodeServerPassword")
      || environment["OpenCodeServerPassword"] != nil || environment["OPENCODE_SERVER_PASSWORD"] != nil
    else { return nil }
    return launch(arguments: arguments, environment: environment)
  }
}

public struct ServerInfo: Codable, Sendable {
  public let version: String?
  public let paths: Paths?
  public struct Paths: Codable, Sendable { public let tmp: String }
  private enum CodingKeys: String, CodingKey { case version, paths }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // Legacy health responses can have no string version; classify that separately
    // from transport failures rather than losing it as an ordinary decoding error.
    version = try? values.decode(String.self, forKey: .version)
    paths = try? values.decode(Paths.self, forKey: .paths)
  }
}
public struct Empty: Codable, Sendable { public init() {} }

public struct OpenCodeClient: Sendable {
  public let configuration: ServerConfiguration
  private let session: URLSession
  private var transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?

  public init(configuration: ServerConfiguration) {
    self.configuration = configuration
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 45
    config.timeoutIntervalForResource = 60 * 60
    session = URLSession(configuration: config)
  }
  init(
    configuration: ServerConfiguration,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    self.init(configuration: configuration)
    self.transport = transport
  }

  public func info() async throws -> ServerInfo {
    let info: ServerInfo = try await get("/api/info")
    guard let version = info.version, !version.isEmpty else { throw ClientError.incompatibleServer }
    return info
  }
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
  public func conversation(_ sessionID: String, cursor: String? = nil) async throws
    -> ConversationPage
  {
    struct Input: Encodable {
      let sessionID: String
      let limit = 40
      let order: String?
      let cursor: String?
    }
    return try await rpc(
      "custom.transcript", "list",
      input: Input(sessionID: sessionID, order: cursor == nil ? "desc" : nil, cursor: cursor))
  }
  public func session(_ id: String) async throws -> Session {
    let response: DataResponse<Session> = try await get("/api/session/\(id)")
    return response.data
  }
  public func models(directory: String? = nil) async throws -> [ModelInfo] {
    let response: DataResponse<[ModelInfo]> = try await get(
      "/api/model", query: directory.map { [URLQueryItem(name: "location[directory]", value: $0)] } ?? [])
    return response.data
  }
  public func defaultModel(directory: String) async throws -> ModelInfo? {
    struct Response: Decodable { let data: ModelInfo? }
    let response: Response = try await get(
      "/api/model/default", query: [URLQueryItem(name: "location[directory]", value: directory)])
    return response.data
  }
  public func agents(directory: String) async throws -> [AgentInfo] {
    let response: DataResponse<[AgentInfo]> = try await get(
      "/api/agent", query: [URLQueryItem(name: "location[directory]", value: directory)])
    return response.data
  }
  public func providers(directory: String) async throws -> [ProviderInfo] {
    let response: DataResponse<[ProviderInfo]> = try await get(
      "/api/provider", query: [URLQueryItem(name: "location[directory]", value: directory)])
    return response.data
  }
  public func familyPage(_ sessionID: String, after: String? = nil) async throws -> FamilyPage {
    struct Input: Encodable {
      let sessionID: String
      let limit = 100
      let after: String?
    }
    return try await rpc(
      "custom.session-family", "page", input: Input(sessionID: sessionID, after: after))
  }
  public func shells(directory: String) async throws -> [ShellInfo] {
    let response: DataResponse<[ShellInfo]> = try await get(
      "/api/shell", query: [URLQueryItem(name: "location[directory]", value: directory)])
    return response.data
  }
  public func shellOutput(_ id: String, directory: String, cursor: Int = 0) async throws
    -> ShellOutput
  {
    let response: DataResponse<ShellOutput> = try await get(
      "/api/shell/\(id)/output",
      query: [
        URLQueryItem(name: "location[directory]", value: directory),
        URLQueryItem(name: "cursor", value: String(cursor)),
        URLQueryItem(name: "limit", value: "65536"),
      ])
    return response.data
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

  public func rpc<Input: Encodable, Output: Decodable>(
    _ id: String, _ method: String, input: Input, directory: String? = nil
  )
    async throws -> Output
  {
    var request = request(
      "/api/rpc/\(id)/\(method)",
      query: directory.map { [URLQueryItem(name: "location[directory]", value: $0)] } ?? [])
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(RPCInput(input: input))
    let data = try await data(request)
    return try JSONDecoder().decode(RPCOutput<Output>.self, from: data).output
  }
  func get<Output: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws
    -> Output
  {
    try JSONDecoder().decode(Output.self, from: await data(request(path, query: query)))
  }
  func post<Input: Encodable>(_ path: String, input: Input) async throws {
    var request = request(path)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(input)
    _ = try await data(request)
  }
  func perform(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil)
    async throws
  {
    var request = request(path, query: query)
    request.httpMethod = method
    request.httpBody = body
    _ = try await data(request)
  }
  func data(_ request: URLRequest) async throws -> Data {
    let (data, response) =
      if let transport {
        try await transport(request)
      } else {
        try await session.data(for: request)
      }
    if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      value.object?["_tag"]?.string == "LocationNotFoundError",
      let directory = value.object?["location"]?.object?["directory"]?.string
    {
      throw ClientError.locationNotFound(directory)
    }
    try validate(response)
    return data
  }
  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
  }
  func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
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
  case incompatibleServer
  case locationNotFound(String)
  public var errorDescription: String? {
    switch self {
    case .incompatibleServer: "Este servidor não é compatível com o OpenCode V2."
    case .locationNotFound: "O diretório desta sessão não existe mais."
    case .http(401): "A senha do servidor não foi aceita."
    case .http(let code): "O servidor respondeu com o código \(code)."
    }
  }
}
