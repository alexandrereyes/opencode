import Foundation

extension OpenCodeClient {
  public func imageFileRequest(path: String) -> URLRequest {
    let file = URL(fileURLWithPath: path)
    var result = request("/api/fs/read/\(file.lastPathComponent)", query: [
      URLQueryItem(name: "location[directory]", value: file.deletingLastPathComponent().path)
    ])
    result.setValue("image/*", forHTTPHeaderField: "Accept")
    result.setValue("bytes=0-\(FeedImageLoader.maximumBytes)", forHTTPHeaderField: "Range")
    result.timeoutInterval = 20
    return result
  }

  public func imageFile(path: String) async throws -> Data {
    try await data(imageFileRequest(path: path))
  }

  public func imageRemoteRequest(_ url: URL) throws -> URLRequest {
    let server = configuration.url
    let sameOrigin = url.scheme == server.scheme && url.host == server.host && url.port == server.port
    let local = FeedImageReference.isLoopback(url.host)
    // Only the backend's known file route can safely move between server origins.
    // An arbitrary localhost web server is not an OpenCode reverse proxy.
    guard !local || sameOrigin || url.path.hasPrefix("/api/fs/read/") else {
      throw FeedImageFailure.loopbackUnavailable
    }
    if sameOrigin || local {
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
      var result = request(url.path, query: components.queryItems ?? [])
      result.setValue("image/*", forHTTPHeaderField: "Accept")
      result.setValue("bytes=0-\(FeedImageLoader.maximumBytes)", forHTTPHeaderField: "Range")
      result.timeoutInterval = 20
      return result
    }
    var result = URLRequest(url: url)
    result.timeoutInterval = 20
    result.setValue("image/*", forHTTPHeaderField: "Accept")
    result.setValue("bytes=0-\(FeedImageLoader.maximumBytes)", forHTTPHeaderField: "Range")
    return result
  }

  public func imageRemote(_ url: URL) async throws -> Data {
    let request = try imageRemoteRequest(url)
    if request.value(forHTTPHeaderField: "Authorization") != nil
      || request.url?.host == configuration.url.host {
      return try await data(request)
    }
    let (bytes, response) = try await ImageTransport.session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    guard response.expectedContentLength <= FeedImageLoader.maximumBytes else {
      throw FeedImageFailure.tooLarge
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < FeedImageLoader.maximumBytes else { throw FeedImageFailure.tooLarge }
      data.append(byte)
    }
    return data
  }

  public func imageMessage(sessionID: String, messageID: String) async throws -> ConversationMessage {
    let response: DataResponse<ConversationMessage> = try await get(
      "/api/session/\(sessionID)/message/\(messageID)")
    return response.data
  }
}

private enum ImageTransport {
  static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 45
    return URLSession(configuration: configuration)
  }()
}
