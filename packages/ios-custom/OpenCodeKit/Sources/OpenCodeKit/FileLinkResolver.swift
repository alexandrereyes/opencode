import Foundation

/// What a local path in a response names on the server.
public enum FileLinkTarget: Sendable, Equatable {
  case file
  case directory(String)
}

extension OpenCodeClient {
  /// A folder opens in the explorer, a file in the viewer; nil leaves the text as it is.
  public func fileLinkTarget(_ source: String, directory: String) async throws -> FileLinkTarget? {
    if let folder = try await folderMatch(source, directory: directory) { return .directory(folder) }
    return try await fileLinkMatches(source, directory: directory).isEmpty ? nil : .file
  }

  /// The exact path first, then, for relative paths, a unique folder ending with it, as files are matched.
  private func folderMatch(_ source: String, directory: String) async throws -> String? {
    guard let path = FileReference.local(source) else { return nil }
    let home = path.hasPrefix("~") ? try await serverHome() : nil
    let absolute = ProjectExplorer.canonical(try FeedImageReference(path).path(directory: directory, home: home))
    if absolute != "/", let parent = FileExplorer.parent(absolute),
      let entries = try? await listDirectory(parent, location: directory),
      entries.contains(where: { $0.kind == .directory && $0.absolute == absolute }) {
      return absolute
    }
    guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
    // A path leaving the Session directory was already answered by the exact listing above.
    guard !path.split(separator: "/").contains(".."), case let query = String(ProjectExplorer.canonical("/" + path).dropFirst()),
      !query.isEmpty else { return nil }
    struct Entry: Codable { let path: String; let type: String }
    let response: DataResponse<[Entry]> = try await get("/api/fs/find", query: [
      URLQueryItem(name: "location[directory]", value: directory),
      URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "directory"),
      URLQueryItem(name: "limit", value: "200"),
    ])
    let folders = Set(response.data.filter { $0.type == "directory" }
      .map { $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path }
      .filter { $0 == query || $0.hasSuffix("/" + query) })
    guard folders.count == 1, let folder = folders.first else { return nil }
    return ProjectExplorer.canonical(directory + "/" + folder)
  }

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
