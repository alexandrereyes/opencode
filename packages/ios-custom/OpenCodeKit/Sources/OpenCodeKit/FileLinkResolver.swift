import Foundation

extension OpenCodeClient {
  public func fileLinkMatches(_ source: String, directory: String) async throws -> [String] {
    guard let path = FileReference.local(source) else { return [] }
    struct Entry: Codable { let path: String; let type: String }
    if path.hasPrefix("/") || path.hasPrefix("~") {
      let home = path.hasPrefix("~") ? try await serverHome() : nil
      let file = URL(fileURLWithPath: try FeedImageReference(path).path(directory: directory, home: home))
      let response: DataResponse<[Entry]> = try await get("/api/fs/list", query: [
        URLQueryItem(name: "location[directory]", value: file.deletingLastPathComponent().path)
      ])
      return response.data.contains { $0.type == "file" && $0.path == file.lastPathComponent } ? [file.path] : []
    }
    let normalized = path.split(separator: "/", omittingEmptySubsequences: true).reduce(into: [String]()) { parts, next in
      if next == "." { return }
      if next == "..", let last = parts.last, last != ".." { parts.removeLast(); return }
      parts.append(String(next))
    }.joined(separator: "/")
    let query = normalized.replacingOccurrences(of: #"^(?:\.\./)+"#, with: "", options: .regularExpression)
    guard !query.isEmpty else { return [] }
    let response: DataResponse<[Entry]> = try await get("/api/fs/find", query: [
      URLQueryItem(name: "location[directory]", value: directory),
      URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "file"),
      URLQueryItem(name: "limit", value: "200"),
    ])
    let paths = Array(Set(response.data.filter { $0.type == "file" }.map(\.path)
      .filter { $0 == query || $0.hasSuffix("/" + query) })).sorted()
    let exact = paths.filter { $0 == normalized }
    return (exact.isEmpty ? paths : exact).map { URL(fileURLWithPath: directory).appendingPathComponent($0).standardized.path }
  }
}
