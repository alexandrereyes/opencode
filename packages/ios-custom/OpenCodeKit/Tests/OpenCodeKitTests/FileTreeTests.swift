import Foundation
import Testing
@testable import OpenCodeKit

private func folder(_ path: String) -> DirectoryEntry {
  DirectoryEntry(name: URL(fileURLWithPath: path).lastPathComponent, absolute: path, kind: .directory)
}
private func file(_ path: String) -> DirectoryEntry {
  DirectoryEntry(name: URL(fileURLWithPath: path).lastPathComponent, absolute: path, kind: .file)
}

/// The session `/s` with `reports/` (two files), `notes/` (one file deeper) and a file at the top.
private func session() -> FileTree {
  var tree = FileTree(root: "/s")
  tree.store([file("/s/README.md"), folder("/s/reports"), folder("/s/notes")], in: "/s")
  tree.store([file("/s/reports/Mac Studio.md"), file("/s/reports/resumo.md")], in: "/s/reports")
  tree.store([folder("/s/notes/fontes")], in: "/s/notes")
  tree.store([file("/s/notes/fontes/fontes.md")], in: "/s/notes/fontes")
  return tree
}

private func names(_ rows: [FileTree.Row]) -> [String] {
  rows.map { String(repeating: "  ", count: $0.depth) + $0.entry.name + ($0.directory ? ($0.open ? "/ ▾" : "/") : "") }
}

@Test func fileTreeListsFoldersFirstAndOpensOnlyExpandedFolders() {
  var tree = session()
  #expect(names(tree.rows(statuses: [:], onlyChanged: false, filter: "")) == ["notes/", "reports/", "README.md"])
  tree.toggle("/s/reports")
  #expect(names(tree.rows(statuses: [:], onlyChanged: false, filter: ""))
    == ["notes/", "reports/ ▾", "  Mac Studio.md", "  resumo.md", "README.md"])
  tree.toggle("/s/reports")
  #expect(!tree.expanded.contains("/s/reports"))
}

@Test func fileTreeRevealsALinkedFileAndListsWhatIsMissing() {
  var tree = FileTree(root: "/s")
  #expect(tree.reveal("/s/notes/fontes/fontes.md") == ["/s", "/s/notes", "/s/notes/fontes"])
  #expect(tree.expanded == ["/s/notes", "/s/notes/fontes"])
  #expect(tree.unlisted == ["/s", "/s/notes", "/s/notes/fontes"])
  tree = session()
  #expect(tree.reveal("/s/notes/fontes/fontes.md").isEmpty)
  #expect(names(tree.rows(statuses: [:], onlyChanged: false, filter: ""))
    == ["notes/ ▾", "  fontes/ ▾", "    fontes.md", "reports/", "README.md"])
  // A folder outside the session becomes the top.
  #expect(tree.reveal("/outro/arquivo.md") == ["/outro"])
  #expect(tree.root == "/outro")
  #expect(tree.reveal("/outro/pasta", directory: true) == ["/outro", "/outro/pasta"])
}

@Test func fileTreeFilterKeepsMatchesAndTheFoldersLeadingToThem() {
  let tree = session()
  #expect(names(tree.rows(statuses: [:], onlyChanged: false, filter: "FONTES.md"))
    == ["notes/ ▾", "  fontes/ ▾", "    fontes.md"])
  // Accents and case are ignored; a matching folder keeps its listing.
  #expect(names(tree.rows(statuses: [:], onlyChanged: false, filter: "RÉPORTS")) == ["reports/"])
  var expanded = tree
  expanded.toggle("/s/reports")
  #expect(names(expanded.rows(statuses: [:], onlyChanged: false, filter: "reports"))
    == ["reports/ ▾", "  Mac Studio.md", "  resumo.md"])
  #expect(tree.rows(statuses: [:], onlyChanged: false, filter: "nada").isEmpty)
}

@Test func fileTreeAlteradosNeedsNoListing() {
  let status = ContextColumn.FileStatus(change: .modified, additions: 12, deletions: 0)
  let statuses = ["/s/notes/fontes/fontes.md": status, "/s/README.md": status, "/fora/x.md": status]
  let tree = FileTree(root: "/s")
  #expect(names(tree.rows(statuses: statuses, onlyChanged: true, filter: ""))
    == ["notes/ ▾", "  fontes/ ▾", "    fontes.md", "README.md"])
  #expect(names(tree.rows(statuses: statuses, onlyChanged: true, filter: "read")) == ["README.md"])
}

@Test func fileHistoryGoesBackAndForwardAndDropsWhatWasAhead() {
  var history = FileHistory()
  history.visit("/a")
  history.visit("/b")
  history.visit("/b")
  history.visit("/c")
  #expect(history.back == ["/a", "/b"] && history.current == "/c" && !history.canGoForward)
  #expect(history.goBack() == "/b")
  #expect(history.goBack() == "/a")
  #expect(history.goBack() == nil)
  #expect(history.goForward() == "/b")
  history.visit("/d")
  #expect(history.back == ["/a", "/b"] && history.forward.isEmpty && history.current == "/d")
}

@Test func fileRecentsKeepTheLastFilesPerFolderAcrossLaunches() throws {
  let defaults = try #require(UserDefaults(suiteName: "FileRecentsTests-\(UUID().uuidString)"))
  let server = URL(string: "http://127.0.0.1:4178")!
  var recents = FileRecents.load(server: server, directory: "/s", defaults: defaults)
  for index in 0..<10 { recents.add("/s/\(index).md") }
  recents.add("/s/3.md")
  #expect(recents.paths.count == FileRecents.limit)
  #expect(recents.paths.prefix(3) == ["/s/3.md", "/s/9.md", "/s/8.md"])
  recents.save(server: server, directory: "/s/", defaults: defaults)
  #expect(FileRecents.load(server: server, directory: "/s", defaults: defaults) == recents)
  #expect(FileRecents.load(server: server, directory: "/outra", defaults: defaults).paths.isEmpty)
}
