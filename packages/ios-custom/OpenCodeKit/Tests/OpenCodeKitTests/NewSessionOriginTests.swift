import Foundation
import Testing

@testable import OpenCodeKit

private func originSession(_ directory: String, project: String = "a") throws -> Session {
  try JSONDecoder().decode(
    Session.self,
    from: Data(
      #"{"id":"ses_o","projectID":"\#(project)","location":{"directory":"\#(directory)"},"time":{"created":1,"updated":1},"agent":"plan"}"#
        .utf8))
}
private let originProjects: [Project] = try! JSONDecoder().decode(
  [Project].self,
  from: Data(#"[{"id":"a","canonical":"/repo","sandboxes":["/worktrees/repo-feat"]}]"#.utf8))

@Test func newSessionOriginKeepsProjectCheckoutAndModelButNotAgent() throws {
  let model = ModelReference(id: "luna", providerID: "proxy", variant: "low")
  let root = try #require(
    NewSessionOrigin(
      session: originSession("/repo/"), projects: originProjects, chatRoot: "/chats", model: model))
  #expect(root == NewSessionOrigin(projectID: "a", destination: .root, model: model))
  let worktree = try #require(
    NewSessionOrigin(
      session: originSession("/worktrees/repo-feat"), projects: originProjects, chatRoot: nil,
      model: nil))
  #expect(worktree.destination == .worktree("/worktrees/repo-feat"))
  #expect(worktree.destination.directory(root: "/repo") == "/worktrees/repo-feat")
  #expect(!worktree.chat && worktree.model == nil)
  let unlisted = try originSession("/elsewhere", project: "missing")
  #expect(
    NewSessionOrigin(session: unlisted, projects: originProjects, chatRoot: "/chats", model: model)
      == nil)
}

@Test func newSessionOriginFromAChatSelectsChatsWithTheSameModel() throws {
  let model = ModelReference(id: "luna", providerID: "proxy", variant: "medium")
  for directory in ["/chats", "/chats/2026/x"] {
    let chat = try originSession(directory, project: "global")
    let origin = try #require(
      NewSessionOrigin(session: chat, projects: originProjects, chatRoot: "/chats", model: model))
    #expect(origin.chat && origin.projectID.isEmpty && origin.model == model)
  }
  // Without a resolved chats root a chat is indistinguishable from an unlisted project.
  let chat = try originSession("/chats/x", project: "global")
  #expect(
    NewSessionOrigin(session: chat, projects: originProjects, chatRoot: nil, model: model) == nil)
  let sibling = try originSession("/chats-other", project: "global")
  #expect(
    NewSessionOrigin(session: sibling, projects: originProjects, chatRoot: "/chats", model: model)
      == nil)
}
