import Foundation

public enum FeedImageReference: Sendable, Equatable {
  case data(String)
  case local(String)
  case remote(URL)
  case unsupported(String)

  public init(_ source: String) {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("//") { self = .unsupported(value); return }
    if value.hasPrefix("data:") { self = .data(value); return }
    if value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL,
      url.host == nil || url.host == "" || url.host == "localhost"
    { self = .local(url.path); return }
    if let url = URL(string: value), let scheme = url.scheme {
      self = ["http", "https"].contains(scheme.lowercased()) && url.host != nil
        && url.user == nil && url.password == nil ? .remote(url) : .unsupported(value)
      return
    }
    self = value.isEmpty ? .unsupported(value) : .local(value)
  }

  public static func isLoopback(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
      || host == "[::1]" || host.hasPrefix("127.")
  }

  public func path(directory: String, home: String?) throws -> String {
    guard case .local(let value) = self else { throw FeedImageFailure.unsupported }
    if value == "~" || value.hasPrefix("~/") {
      guard let home else { throw FeedImageFailure.homeUnavailable }
      return URL(fileURLWithPath: home).appendingPathComponent(String(value.dropFirst(2)))
        .standardized.path
    }
    guard !value.hasPrefix("~") else { throw FeedImageFailure.unsupported }
    return (value.hasPrefix("/") ? URL(fileURLWithPath: value)
      : URL(fileURLWithPath: directory).appendingPathComponent(value)).standardized.path
  }

  public static func display(_ source: String) -> String {
    if source.hasPrefix("data:") { return "Imagem incorporada" }
    guard var url = URLComponents(string: source), url.scheme != nil, url.scheme != "file" else {
      return source
    }
    url.user = nil
    url.password = nil
    url.query = nil
    url.fragment = nil
    return url.string ?? "Imagem"
  }
}

public enum FeedImageFailure: Error, LocalizedError, Sendable, Equatable {
  case unsupported, homeUnavailable, invalidImage, tooLarge, loopbackUnavailable
  case unavailable, authentication, outsideDirectory, network

  public var errorDescription: String? {
    switch self {
    case .unsupported: "Formato de imagem não suportado."
    case .homeUnavailable: "Não foi possível localizar a pasta pessoal do servidor."
    case .invalidImage: "O conteúdo não é uma imagem compatível."
    case .tooLarge: "A imagem excede o limite de 32 MB."
    case .loopbackUnavailable: "Este endereço só funciona no computador do servidor."
    case .authentication: "A autenticação do servidor não foi aceita."
    case .outsideDirectory: "O servidor não permite ler este caminho."
    case .network: "O endereço não está acessível pela rede do iPhone."
    case .unavailable: "O arquivo não está disponível no servidor."
    }
  }
  public static func map(_ error: any Error) -> Self {
    if let error = error as? Self { return error }
    if let error = error as? ClientError {
      switch error {
      case .http(401): return .authentication
      case .http(403): return .outsideDirectory
      default: return .unavailable
      }
    }
    return error is URLError ? .network : .unavailable
  }
}

public struct FeedImage: Sendable, Equatable {
  public let source: String
  public let name: String
  public init(source: String, name: String = "Imagem") {
    self.source = source
    self.name = name.isEmpty ? "Imagem" : name
  }

  public static func attachment(_ value: JSONValue) -> Self? {
    guard let object = value.object,
      (object["mime"]?.string ?? object["mimeType"]?.string)?.hasPrefix("image/") == true
        || object["type"]?.string == "image"
    else { return nil }
    let name = object["name"]?.string ?? "Imagem"
    if let data = object["data"]?.string {
      return Self(source: data.hasPrefix("data:") ? data
        : "data:\(object["mime"]?.string ?? object["mimeType"]?.string ?? "image/png");base64,\(data)", name: name)
    }
    if let url = object["uri"]?.string ?? object["url"]?.string ?? object["path"]?.string {
      if url.hasPrefix("data:"), url.hasSuffix("base64,") { return nil }
      return Self(source: url, name: name)
    }
    return nil
  }
}
