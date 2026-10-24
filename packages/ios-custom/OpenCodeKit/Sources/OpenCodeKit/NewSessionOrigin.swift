import Foundation

/// What a new session started from an existing one inherits, matching the web's "Nova sessão":
/// Chats for a managed chat, otherwise the same project and checkout (main directory or that existing
/// worktree, whose branch it already has), plus the composer's current model and effort.
/// The agent is not inherited.
public struct NewSessionOrigin: Codable, Sendable, Hashable {
  /// Empty for a chat.
  public let projectID: String
  public let destination: SessionDestination
  public let chat: Bool
  public let model: ModelReference?
  public init(
    projectID: String, destination: SessionDestination, chat: Bool = false, model: ModelReference?
  ) {
    self.projectID = projectID
    self.destination = destination
    self.chat = chat
    self.model = model
  }
  public init?(session: Session, projects: [Project], chatRoot: String?, model: ModelReference?) {
    let directory = session.location.directory
    if let chatRoot, directory == chatRoot || directory.hasPrefix(chatRoot + "/") {
      self.init(projectID: "", destination: .root, chat: true, model: model)
      return
    }
    guard let project = projects.first(where: { $0.id == session.projectID }) else { return nil }
    let root =
      URL(fileURLWithPath: directory).standardizedFileURL.path
      == URL(fileURLWithPath: project.canonical).standardizedFileURL.path
    self.init(projectID: project.id, destination: root ? .root : .worktree(directory), model: model)
  }
}
