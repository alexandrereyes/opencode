import Foundation
import Testing

@testable import OpenCodeKit

private let home = "/Users/me"

@Test func projectExplorerStartsInDevAndSplitsPathFromFilter() {
  #expect(ProjectExplorer.start(home: home, fallback: "/srv") == "~/Dev/")
  #expect(ProjectExplorer.start(home: "", fallback: "/srv/app") == "/srv/app/")
  let query = ProjectExplorer.query("~/Dev/op", home: home)
  #expect(query.directory == "~/Dev/")
  #expect(query.filter == "op")
  #expect(query.browsed == "/Users/me/Dev")
  #expect(query.target == "/Users/me/Dev/op")
  #expect(ProjectExplorer.query("~/Dev/../Worktrees//", home: home).browsed == "/Users/me/Worktrees")
  #expect(ProjectExplorer.query("relative/", home: home).browsed == "")
  #expect(ProjectExplorer.query("~/", home: "").browsed == "")
}

@Test func projectExplorerParentWalksUpToTheRootOnlyWhileBrowsing() {
  #expect(ProjectExplorer.parent("~/Dev/", home: home) == "~/")
  #expect(ProjectExplorer.parent("~/", home: home) == "/Users/")
  #expect(ProjectExplorer.parent("/Users/", home: home) == "/")
  #expect(ProjectExplorer.parent("/", home: home) == nil)
  #expect(ProjectExplorer.parent("~/Dev/op", home: home) == nil)
  #expect(ProjectExplorer.display("/opt/data", home: home) == "/opt/data/")
}

@Test func projectExplorerRowsFilterSortAndMarkAddedOrBlocked() {
  let entries = [
    ProjectExplorer.Entry(name: "zeta", absolute: "/Users/me/zeta/"),
    ProjectExplorer.Entry(name: ".hidden", absolute: "/Users/me/.hidden"),
    ProjectExplorer.Entry(name: "Alpha", absolute: "/Users/me/Alpha"),
    ProjectExplorer.Entry(name: "me", absolute: "/Users/me"),
  ]
  let rows = ProjectExplorer.rows(
    entries: entries, filter: "", hidden: false, added: ["/Users/me/zeta"], home: home)
  #expect(rows.map(\.name) == ["Alpha", "me", "zeta"])
  #expect(rows.map(\.added) == [false, false, true])
  #expect(rows.map(\.blocked) == [false, true, false])
  #expect(
    ProjectExplorer.rows(entries: entries, filter: ".", hidden: false, added: [], home: home)
      .map(\.name) == [".hidden"])
  #expect(
    ProjectExplorer.rows(entries: entries, filter: "AL", hidden: false, added: [], home: home)
      .map(\.name) == ["Alpha"])
}

@Test func projectExplorerSubmissionMatchesTheWeb() {
  let rows = ProjectExplorer.rows(
    entries: [ProjectExplorer.Entry(name: "app", absolute: "/Users/me/Dev/app")], filter: "",
    hidden: false, added: [], home: home)
  func submit(_ query: String, added: Set<String> = [], readable: Bool = true) -> ProjectExplorer
    .Submission?
  {
    ProjectExplorer.submission(
      query: query, home: home, added: added, readable: readable, rows: rows)
  }
  #expect(submit("~/Dev/") == .existing("/Users/me/Dev"))
  #expect(submit("~/Dev/app") == .existing("/Users/me/Dev/app"))
  #expect(submit("~/Dev/novo") == .create("/Users/me/Dev/novo"))
  #expect(submit("~/Dev/", added: ["/Users/me/Dev"]) == .added("/Users/me/Dev"))
  #expect(submit("~/Dev/", readable: false) == nil)
  #expect(submit("~/") == nil)
  #expect(submit("/") == nil)
}

@Test func projectExplorerListsDirectoriesRelativeToTheDefaultLocation() async throws {
  let requests = RequestLog()
  let client = OpenCodeClient(
    configuration: .init(url: URL(string: "http://127.0.0.1:4180")!),
    transport: { request in
      await requests.append(request)
      let body =
        #"{"location":{"directory":"/Users/me/Worktrees/app"},"data":[{"path":"../../Dev/api/","type":"directory"},{"path":"../../Dev/notes.md","type":"file"}]}"#
      return (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    })
  let entries = try await client.directories(at: "/Users/me/Dev")
  #expect(entries == [ProjectExplorer.Entry(name: "api", absolute: "/Users/me/Dev/api")])
  let url = try #require(await requests.values.first?.url)
  #expect(url.path == "/api/fs/list")
  #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/Users/me/Dev")
}

private actor RequestLog {
  var values: [URLRequest] = []
  func append(_ request: URLRequest) { values.append(request) }
}
