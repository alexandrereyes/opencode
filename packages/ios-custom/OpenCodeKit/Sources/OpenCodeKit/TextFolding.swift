import Foundation

/// The app's text folding for local searches: case and accents ignored ("Sessão" matches "sessao").
public enum TextFolding {
  public static func fold(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  }
}

/// The search field of Arquivadas: a session matches when its title, project name or directory contains every
/// word of the query, folded.
public enum ArchivedSessionSearch {
  public static func filter(
    _ sessions: [Session], query: String, project: (Session) -> String?, path: (Session) -> String?
  ) -> [Session] {
    let words = TextFolding.fold(query).split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return sessions }
    return sessions.filter { session in
      let text = TextFolding.fold(
        [session.displayTitle, project(session), path(session), session.location.directory]
          .compactMap { $0 }.joined(separator: "\n"))
      return words.allSatisfy { text.contains($0) }
    }
  }
}
