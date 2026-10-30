import OpenCodeKit
import SwiftUI

/// "Salvar como snippet" in a user message's long-press menu. The handler opens the editor with the message's text;
/// equality ignores it, so the bubbles never re-render for it.
struct UserMessageSnippetAction: Equatable {
  let save: (String) -> Void
  static func == (lhs: Self, rhs: Self) -> Bool { true }
}

/// What a conversation's composer needs to open the snippet editor: the catalog, the projects for the scope and the
/// conversation's own project, where a new snippet starts.
struct SnippetEditorContext {
  let catalog: SnippetCatalog
  let projects: [Project]
  let project: String?

  init(catalog: SnippetCatalog, projects: [Project], project: String?) {
    self.catalog = catalog
    self.projects = projects
    // Chats (project "global") and folders outside a known project start global.
    self.project = project.flatMap { id in id != "global" && projects.contains { $0.id == id } ? id : nil }
  }

  /// The `#` query becomes the name; a message's or selection's text the content, named from its first words.
  @MainActor func route(_ launch: SnippetEditorLaunch) -> SnippetEditorRoute {
    let snippet = launch.content.isEmpty
      ? Snippet(name: launch.name, project: project)
      : SnippetLibrary.draft(content: launch.content, project: project, in: catalog.items)
    return SnippetEditorRoute(snippet: snippet, editing: false)
  }
}

extension EnvironmentValues {
  @Entry var userMessageSnippet: UserMessageSnippetAction? = nil
  @Entry var snippetEditorContext: SnippetEditorContext? = nil
}
