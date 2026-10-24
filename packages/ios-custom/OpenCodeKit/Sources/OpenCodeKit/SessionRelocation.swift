import Foundation

/// Destinations for a Session whose directory vanished, like the web's location-missing dock:
/// the project's root checkout first, then its other worktrees. Moving always waits for a tap.
public enum SessionRelocation {
  /// The root checkout, when it is a Git project other than the vanished directory itself.
  public static func root(_ project: Project?, missing: String) -> String? {
    guard let project, project.vcs == "git", !same(project.canonical, missing) else { return nil }
    return project.canonical
  }
  public static func worktrees(
    root: String, missing: String, inventory: [WorktreeDirectory], sandboxes: [String], branches: [WorktreeBranch]
  ) -> [WorktreeChoice] {
    NewSessionProjection.worktrees(root: root, inventory: inventory, sandboxes: sandboxes, branches: branches)
      .filter { !same($0.directory, missing) }
  }
  /// Descendants still placed in the vanished directory; they move with the Session on request.
  public static func stranded(_ members: [Session], missing: String) -> [Session] {
    members.filter { same($0.location.directory, missing) }
  }
  static func same(_ left: String, _ right: String) -> Bool {
    URL(fileURLWithPath: left).standardizedFileURL.path == URL(fileURLWithPath: right).standardizedFileURL.path
  }
}

extension OpenCodeClient {
  /// `POST /api/session/:id/move`. The server switches an idle Session out of a vanished directory at once.
  public func moveSession(_ id: String, directory: String) async throws {
    struct Input: Encodable { let directory: String }
    try await post("/api/session/\(id)/move", input: Input(directory: directory))
  }
  /// Prunes worktrees removed outside OpenCode before listing, as the web's worktree menu does.
  public func relocationWorktrees(project: Project, missing: String) async throws -> [WorktreeChoice] {
    struct Input: Encodable { let projectID: String }
    guard project.vcs == "git" else { return [] }
    try? await post("/api/worktree/refresh", input: Input(projectID: project.id))
    async let inventory = worktrees(projectID: project.id)
    async let branches = try? worktreeBranches(directory: project.canonical)
    return SessionRelocation.worktrees(
      root: project.canonical, missing: missing, inventory: try await inventory,
      sandboxes: project.sandboxes, branches: await branches ?? [])
  }
  public func strandedDescendants(_ sessionID: String, missing: String) async throws -> [Session] {
    var members: [Session] = []
    var after: String?
    repeat {
      let page = try await familyPage(sessionID, after: after)
      members.append(contentsOf: page.data)
      if page.next == after { break }
      after = page.next
    } while after != nil
    return SessionRelocation.stranded(members, missing: missing)
  }
}
