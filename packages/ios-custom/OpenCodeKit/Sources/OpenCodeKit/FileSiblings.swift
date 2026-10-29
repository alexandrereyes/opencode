import Foundation

/// Files the viewer can page through: same directory, server listing order, viewable kinds only.
public enum FileSiblings {
  /// `listDirectory` keeps the web file tree's order (directories first, then `localeCompare`). Folders and kinds
  /// the viewer cannot preview are skipped, except the open file itself; nil when the file is not listed.
  public static func ordered(_ entries: [DirectoryEntry], current: String) -> [String]? {
    let current = ProjectExplorer.canonical(current)
    let files = entries.filter { $0.kind == .file && ($0.absolute == current || FileViewerKind(path: $0.name) != .unknown) }
      .map(\.absolute)
    return files.contains(current) ? files : nil
  }
}

extension OpenCodeClient {
  /// Siblings of a server file, inside or outside the Session directory; listing never switches Location.
  public func fileSiblings(of path: String, location: String) async throws -> [String]? {
    FileSiblings.ordered(try await listDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path,
      location: location), current: path)
  }
}

extension FileSiblings {
  /// Which paging arrows the viewer shows for the open file at `position` of `count` siblings: none for a single
  /// file or one not in the list, no "previous" on the first and no "next" on the last.
  public static func arrows(position: Int?, count: Int) -> (previous: Bool, next: Bool) {
    guard let position, count > 1, (0..<count).contains(position) else { return (false, false) }
    return (position > 0, position < count - 1)
  }
}
