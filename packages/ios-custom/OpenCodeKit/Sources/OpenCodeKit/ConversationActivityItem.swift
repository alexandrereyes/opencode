import Foundation

public struct ConversationActivityItem: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable { case part, read, files, skills, search }
  public var id: String
  public let kind: Kind
  public var parts: [ConversationActivityPart]
  public var files: [ConversationActivityFile] = []
  private var fileSnapshots: [String: ConversationPart] = [:]

  public static func project(_ parts: [ConversationActivityPart], previous: [Self] = []) -> [Self] {
    let priorParts = Dictionary(previous.flatMap { $0.fileSnapshots.map { ($0.key, $0.value) } }, uniquingKeysWith: { first, _ in first })
    var items: [Self] = []
    for part in parts {
      let kind = part.part.activityKind
      if [.read, .files, .skills].contains(kind), items.last?.kind == kind {
        items[items.count - 1].parts.append(part)
      } else { items.append(Self(id: part.id, kind: kind, parts: [part])) }
    }
    var claimed: Set<String> = []
    let reserved = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    return items.enumerated().map { index, item in
      var item = item
      if let old = previous.first(where: { old in
        old.kind == item.kind && !claimed.contains(old.id) && (reserved[old.id] == nil || reserved[old.id] == index)
          && item.parts.contains { current in old.parts.contains { $0.id == current.id } }
      }) {
        item.id = old.id
        claimed.insert(old.id)
        if old.parts == item.parts { return old }
      }
      if item.kind == .files {
        let snapshots = item.parts.map { entry in
          // The web retains a tool's last file snapshot until its replacement arrives.
          if entry.part.diffs.isEmpty, let prior = priorParts[entry.id], !prior.diffs.isEmpty { return (entry.id, prior) }
          return (entry.id, entry.part)
        }
        item.fileSnapshots = Dictionary(snapshots, uniquingKeysWith: { first, _ in first })
        item.files = ConversationActivityFile.project(snapshots.map(\.1))
      }
      return item
    }
  }
}

extension ConversationPart {
  public var activityKind: ConversationActivityItem.Kind {
    guard type == .tool, status != "error" else { return .part }
    if ["edit", "write", "patch"].contains(name) { return .files }
    if ["glob", "grep", "list"].contains(name) { return .search }
    if name == "skill", skillName?.isEmpty == false { return .skills }
    if name == "read" {
      // Not `URL(fileURLWithPath:)`, which asks the file system whether the path is a folder.
      let ext = ((input["path"]?.string ?? "") as NSString).pathExtension.lowercased()
      let loaded = status == "completed" && metadata["loaded"]?.array?.contains { $0.string != nil } == true
      if !loaded && !["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "ico"].contains(ext) { return .read }
    }
    return .part
  }
  public var skillName: String? { metadata["name"]?.string ?? input["id"]?.string ?? input["name"]?.string }
  public var readGroupName: String {
    let name = (input["path"]?.string ?? "").replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
    return ([name] + ["offset", "limit"].compactMap { key in input[key]?.number.map { "\(key)=\(Int($0))" } }).joined(separator: " ")
  }
}

public struct ConversationActivityFile: Sendable, Equatable, Identifiable {
  public var id: String { path }
  public let path: String
  public var status: String
  public var additions: Int
  public var deletions: Int
  public var patches: [String]
  private var before: String?
  private var after: String?

  public static func project(_ parts: [ConversationPart]) -> [Self] {
    var files: [Self] = []
    for part in parts {
      let values: [Self]
      if !part.diffs.isEmpty {
        values = part.diffs.compactMap { value in
          guard let path = value["file"]?.string, let patch = value["patch"]?.string,
            let add = value["additions"]?.number, let del = value["deletions"]?.number,
            let status = value["status"]?.string, ["added", "deleted", "modified"].contains(status),
            status == "added" || add > 0 || del > 0 else { return nil }
          let contents = complete(patch)
          return Self(path: path, status: status, additions: Int(add), deletions: Int(del), patches: [patch], before: contents?.0, after: contents?.1)
        }
      } else if let path = part.input["path"]?.string {
        if part.name == "edit", let before = part.input["oldString"]?.string, let after = part.input["newString"]?.string, before != after {
          values = [difference(path: path, before: before, after: after)]
        } else if part.name == "write", let after = part.input["content"]?.string {
          var value = difference(path: path, before: "", after: after)
          value.status = after.isEmpty ? "added" : "modified"
          values = [value]
        } else { values = [] }
      } else { values = [] }
      for value in values {
        guard let index = files.firstIndex(where: { $0.path == value.path }) else { files.append(value); continue }
        let old = files[index]
        let status = value.status == "deleted" ? "deleted" : old.status == "added" ? "added" : "modified"
        if let before = old.before, let after = value.after, old.after == value.before {
          files[index] = difference(path: value.path, before: before, after: after)
          files[index].status = status
        } else {
          files[index].status = status
          files[index].additions += value.additions
          files[index].deletions += value.deletions
          files[index].patches += value.patches
          files[index].before = nil
          files[index].after = nil
        }
      }
    }
    return files
  }

  private static func difference(path: String, before: String, after: String) -> Self {
    let old = before.split(separator: "\n", omittingEmptySubsequences: false).dropLast(before.hasSuffix("\n") || before.isEmpty ? 1 : 0).map(String.init)
    let new = after.split(separator: "\n", omittingEmptySubsequences: false).dropLast(after.hasSuffix("\n") || after.isEmpty ? 1 : 0).map(String.init)
    let diff = new.difference(from: old)
    let removed = Set(diff.removals.map { change in if case .remove(let offset, _, _) = change { return offset }; return -1 })
    let inserted = Set(diff.insertions.map { change in if case .insert(let offset, _, _) = change { return offset }; return -1 })
    var lines: [String] = []
    var index = 0
    for (offset, line) in new.enumerated() {
      while index < old.count && removed.contains(index) { lines.append("-" + old[index]); index += 1 }
      if inserted.contains(offset) { lines.append("+" + line) }
      else { lines.append(" " + line); index += 1 }
    }
    while index < old.count { lines.append("-" + old[index]); index += 1 }
    return Self(path: path, status: "modified", additions: inserted.count, deletions: removed.count,
      patches: [lines.joined(separator: "\n")], before: before, after: after)
  }

  private static func complete(_ patch: String) -> (String, String)? {
    guard patch.hasPrefix("diff --git ") || patch.contains("\t\n+++ ") else { return nil }
    let lines = patch.components(separatedBy: "\n")
    let hunks = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
    guard hunks.count == 1, let start = hunks.first,
      lines[start].range(of: #"^@@ -[01](?:,\d+)? \+[01](?:,\d+)? @@"#, options: .regularExpression) != nil else { return nil }
    var before = "", after = ""
    var previous: Character?
    for line in lines.dropFirst(start + 1) {
      if line.hasPrefix("\\") {
        if previous == "-" || previous == " " { if before.hasSuffix("\n") { before.removeLast() } }
        if previous == "+" || previous == " " { if after.hasSuffix("\n") { after.removeLast() } }
        continue
      }
      guard let prefix = line.first else { continue }
      guard ["-", "+", " "].contains(prefix) else { return nil }
      if prefix != "+" { before += line.dropFirst() + "\n" }
      if prefix != "-" { after += line.dropFirst() + "\n" }
      previous = prefix
    }
    return (before, after)
  }
}
