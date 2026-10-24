import Foundation
import Testing

@testable import OpenCodeKit

@Test func fileExplorerParentContinuesAboveTheSessionUpToTheRoot() {
  #expect(FileExplorer.parent("/Users/me/Dev/app") == "/Users/me/Dev")
  #expect(FileExplorer.parent("/Users/me/Dev/app/") == "/Users/me/Dev")
  #expect(FileExplorer.parent("/Users") == "/")
  #expect(FileExplorer.parent("/") == nil)
}

@Test func fileExplorerMapsWorkingChangesFromTheCheckoutRoot() throws {
  let changes = try JSONDecoder().decode([WorkingChange].self, from: Data(#"""
    [{"file":"src/main.swift","additions":1,"deletions":0,"status":"modified"},
     {"file":"docs/new.md","additions":1,"deletions":0,"status":"added"},
     {"file":"old.txt","additions":0,"deletions":3,"status":"deleted"},
     {"file":"legacy.txt","additions":0,"deletions":0}]
    """#.utf8))
  #expect(FileExplorer.changes(changes, root: "/repo/") == [
    "/repo/src/main.swift": .modified, "/repo/docs/new.md": .added, "/repo/old.txt": .deleted,
  ])
  #expect(FileExplorer.Change.added.label == "A")
}

@Test func fileExplorerListsFilesAndFoldersOutsideTheSessionLocation() async throws {
  let requests = ExplorerRequestLog()
  let client = OpenCodeClient(
    configuration: .init(url: URL(string: "http://127.0.0.1:4180")!),
    transport: { request in
      await requests.append(request)
      let body = request.url!.path == "/api/fs/find"
        ? #"{"location":{"directory":"/repo/app"},"data":[{"path":"src/main.swift","type":"file"},{"path":"src/","type":"directory"}]}"#
        : #"{"location":{"directory":"/repo/app"},"data":[{"path":"../.git/","type":"directory"},{"path":"../app/","type":"directory"},{"path":"../.env","type":"file"},{"path":"../README.md","type":"file"}]}"#
      return (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    })
  let entries = try await client.listDirectory("/repo", location: "/repo/app")
  #expect(entries == [
    DirectoryEntry(name: ".git", absolute: "/repo/.git", kind: .directory),
    DirectoryEntry(name: "app", absolute: "/repo/app", kind: .directory),
    DirectoryEntry(name: ".env", absolute: "/repo/.env", kind: .file),
    DirectoryEntry(name: "README.md", absolute: "/repo/README.md", kind: .file),
  ])
  #expect(try await client.findFiles("main", location: "/repo/app") == ["/repo/app/src/main.swift"])
  let urls = await requests.values.compactMap(\.url)
  let list = try #require(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems)
  #expect(list == [
    URLQueryItem(name: "path", value: "/repo"), URLQueryItem(name: "location[directory]", value: "/repo/app"),
  ])
  let find = try #require(URLComponents(url: urls[1], resolvingAgainstBaseURL: false)?.queryItems)
  #expect(urls[1].path == "/api/fs/find")
  #expect(find.contains(URLQueryItem(name: "type", value: "file")))
  #expect(find.contains(URLQueryItem(name: "limit", value: "200")))
}

private actor ExplorerRequestLog {
  var values: [URLRequest] = []
  func append(_ request: URLRequest) { values.append(request) }
}
