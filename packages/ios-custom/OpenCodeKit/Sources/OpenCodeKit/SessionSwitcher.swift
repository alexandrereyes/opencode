import Foundation

/// The conversation header's quick session switcher: the Sessões rows (roots, without archived sessions or the
/// master), chats included, most recent activity first, filtered locally by title, project and branch.
public enum SessionSwitcher {
  public static func rows(
    _ rows: [SessionRow], query: String, label: (Session) -> SessionDirectoryLabel?
  ) -> [SessionRow] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return rows.filter { row in
      guard !query.isEmpty else { return true }
      let directory = label(row.session)
      return [row.session.displayTitle, row.chat ? "Chats" : row.projectName, directory?.branch, directory?.path]
        .compactMap { $0 }
        .contains { $0.localizedStandardContains(query) }
    }.sorted { left, right in
      if left.interactionAt != right.interactionAt { return left.interactionAt > right.interactionAt }
      if left.rank != right.rank { return left.rank > right.rank }
      return left.session.key < right.session.key
    }
  }
}
