import Foundation
import Testing

@testable import OpenCodeKit

private func project(vcs: String? = "git", canonical: String = "/repo") throws -> Project {
  try JSONDecoder().decode(Project.self, from: Data("""
    {"id":"prj","canonical":"\(canonical)","sandboxes":["/wt/b"],\(vcs.map { "\"vcs\":\"\($0)\"," } ?? "")"worktrees":[]}
    """.utf8))
}

private func session(_ id: String, _ directory: String, parent: String? = "ses_root") -> String {
  #"{"id":"\#(id)","parentID":\#(parent.map { "\"\($0)\"" } ?? "null"),"projectID":"prj","location":{"directory":"\#(directory)"},"time":{"created":1,"updated":1}}"#
}

private func ok(_ request: URLRequest, _ body: String = "") -> (Data, URLResponse) {
  (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: body.isEmpty ? 204 : 200, httpVersion: nil, headerFields: nil)!)
}

@Test func relocationRootIsOnlyAnotherGitCheckout() throws {
  #expect(SessionRelocation.root(try project(), missing: "/wt/gone") == "/repo")
  #expect(SessionRelocation.root(try project(), missing: "/repo/") == nil)
  #expect(SessionRelocation.root(try project(vcs: nil), missing: "/wt/gone") == nil)
  #expect(SessionRelocation.root(nil, missing: "/wt/gone") == nil)
}

@Test func moveSessionPostsOnlyTheDirectory() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/session/ses_a/move")
    #expect(request.url?.query == nil)
    let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
    #expect(body == .object(["directory": .string("/repo")]))
    return ok(request)
  }
  try await client.moveSession("ses_a", directory: "/repo")
}

@Test func moveSessionFailureSurfacesTheServerError() async {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    (Data(#"{"_tag":"InvalidRequestError","message":"Destination not found"}"#.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
  }
  await #expect(throws: (any Error).self) { try await client.moveSession("ses_a", directory: "/nope") }
}

@Test func relocationWorktreesRefreshThenListOtherCheckoutsWithBranches() async throws {
  let paths = PathLog()
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    let path = request.url!.path
    await paths.append(request.httpMethod! + " " + path)
    switch path {
    case "/api/worktree/refresh":
      let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
      #expect(body == .object(["projectID": .string("prj")]))
      return ok(request)
    case "/api/worktree":
      #expect(request.url?.query == "projectID=prj")
      return ok(request, #"[{"directory":"/repo"},{"directory":"/wt/gone","strategy":"git"},{"directory":"/wt/a","strategy":"git"}]"#)
    default:
      #expect(path == "/api/rpc/custom.worktrees/branches")
      #expect(request.url?.query == "location%5Bdirectory%5D=/repo" || request.url?.query == "location[directory]=/repo")
      return ok(request, #"{"output":[{"directory":"/wt/a","branch":"feature-a"}]}"#)
    }
  }
  let choices = try await client.relocationWorktrees(project: try project(), missing: "/wt/gone")
  #expect(choices == [WorktreeChoice(directory: "/wt/a", label: "feature-a"), WorktreeChoice(directory: "/wt/b", label: "b")])
  #expect(await paths.values.first == "POST /api/worktree/refresh")
}

@Test func relocationWorktreesSkipNonGitProjectsWithoutRequests() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    Issue.record("Projetos sem Git não consultam worktrees: \(request.url!.path)")
    return ok(request)
  }
  #expect(try await client.relocationWorktrees(project: try project(vcs: nil), missing: "/wt/gone").isEmpty)
}

@Test func strandedDescendantsPageTheFamilyAndKeepOnlyTheVanishedDirectory() async throws {
  let client = OpenCodeClient(configuration: ServerConfiguration(url: URL(string: "http://localhost:4177")!)) { request in
    #expect(request.url?.path == "/api/rpc/custom.session-family/page")
    let input = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!).object?["input"]?.object
    #expect(input?["sessionID"]?.string == "ses_root")
    if input?["after"]?.string == nil {
      return ok(request, #"{"output":{"data":[\#(session("ses_1", "/wt/gone")),\#(session("ses_2", "/repo"))],"next":"ses_2"}}"#)
    }
    return ok(request, #"{"output":{"data":[\#(session("ses_3", "/wt/gone/", parent: "ses_1"))]}}"#)
  }
  let stranded = try await client.strandedDescendants("ses_root", missing: "/wt/gone")
  #expect(stranded.map(\.id) == ["ses_1", "ses_3"])
}

private actor PathLog {
  var values: [String] = []
  func append(_ value: String) { values.append(value) }
}
