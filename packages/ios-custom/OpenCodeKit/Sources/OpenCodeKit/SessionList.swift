import Foundation

public enum SessionState: Int, Sendable {
  case stopped, unread, running, question, permission
}

public struct SessionRow: Sendable, Identifiable {
  public let entry: NavigationEntry
  public let project: Project?
  public let memberIDs: Set<String>
  public let state: SessionState
  public let unread: Bool
  public let pinned: Bool
  public let muted: Bool
  public let activeChildren: Int
  public let requestCount: Int
  public let rank: Double
  /// A managed `custom.chats` conversation: listed under Chats, never under Recentes or a project.
  public var chat = false
  public var id: String { entry.session.id }
  public var session: Session { entry.session }
  public var interactionAt: Double { entry.messageAt ?? session.time.created }
  public var projectName: String {
    if chat { return session.displayTitle }
    return project?.displayName ?? URL(fileURLWithPath: session.location.directory).lastPathComponent
  }
}

public enum SessionFilter: String, CaseIterable, Identifiable, Sendable {
  case all = "Todas"
  case unread = "Não lidas"
  case pinned = "Fixadas"
  case running = "Rodando"
  case attention = "Precisa de você"
  case muted = "Silenciadas"
  public var id: Self { self }
  public func includes(_ row: SessionRow) -> Bool {
    switch self {
    case .all: true
    case .unread: row.unread
    case .pinned: row.pinned
    case .running: row.state == .running
    case .attention: row.state == .permission || row.state == .question
    case .muted: row.muted
    }
  }
}

public enum SessionList {
  public static func rows(
    entries: [NavigationEntry], projects: [Project], active: Set<String>,
    pins: [String], muted: [String], autoApprove: Bool,
    ranks: [String: Double], chatRoot: String?
  ) -> [SessionRow] {
    let pinnedIDs = pins.compactMap(SessionPreferenceKey.sessionID)
    let mutedIDs = Set(muted.compactMap(SessionPreferenceKey.sessionID))
    let index = Dictionary(uniqueKeysWithValues: entries.map { ($0.session.id, $0) })
    var families: [String: [NavigationEntry]] = [:]
    for entry in entries where entry.session.time.archived == nil {
      var root = entry
      var seen: Set<String> = [root.session.id]
      while let parentID = root.session.parentID, let parent = index[parentID],
        !seen.contains(parentID)
      {
        seen.insert(parentID)
        root = parent
      }
      guard root.session.parentID == nil, root.session.time.archived == nil else { continue }
      families[root.session.id, default: []].append(entry)
    }
    return entries.filter { entry in
      entry.session.parentID == nil && entry.session.time.archived == nil
    }.map { entry in
      let session = entry.session
      let members = families[session.id] ?? [entry]
      let permissions =
        autoApprove
        ? 0 : members.reduce(0) { $0 + ($1.permissionAt == nil ? 0 : ($1.permissionCount ?? 1)) }
      let questions = members.reduce(0) {
        $0 + ($1.questionAt == nil ? 0 : ($1.questionCount ?? 1))
      }
      let running = members.contains { active.contains($0.session.id) }
      let idle =
        session.outcome == .succeeded || session.outcome == .failed ? session.time.idle : nil
      let unread = max(entry.unreadAt ?? 0, idle ?? 0) > (session.time.viewed ?? 0)
      return SessionRow(
        entry: entry, project: projects.first { $0.id == session.projectID },
        memberIDs: Set(members.map { $0.session.id }),
        state: permissions > 0
          ? .permission
          : questions > 0 ? .question : running ? .running : unread ? .unread : .stopped,
        unread: unread, pinned: pinnedIDs.contains(session.id),
        muted: mutedIDs.contains(session.id),
        activeChildren: members.filter {
          $0.session.parentID != nil && active.contains($0.session.id)
        }.count,
        requestCount: permissions + questions, rank: ranks[session.id] ?? session.time.updated,
        chat: chatRoot.map { session.location.directory.hasPrefix($0 + "/") } ?? false)
    }.sorted { left, right in
      if left.pinned != right.pinned { return left.pinned }
      if left.pinned, let a = pinnedIDs.firstIndex(of: left.id),
        let b = pinnedIDs.firstIndex(of: right.id), a != b
      {
        return a < b
      }
      if left.rank != right.rank { return left.rank > right.rank }
      return left.session.key < right.session.key
    }
  }

  public static func monogram(_ name: String) -> String {
    let words = name.split { !$0.isLetter && !$0.isNumber }
    if words.count > 1 { return String(words.prefix(2).compactMap(\.first)).uppercased() }
    return String((words.first.map(String.init) ?? name).prefix(2)).uppercased()
  }

  public static func avatarColor(_ project: Project?, fallback: String) -> String {
    let colors = ["lime", "orange", "purple", "cyan", "pink", "mint"]
    if let color = project?.icon?.color, colors.contains(color) { return color }
    let hash = (project?.id ?? fallback).utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return colors[Int(hash % UInt64(colors.count))]
  }
}

public struct RecentOrder: Sendable {
  public private(set) var ranks: [String: Double] = [:]
  private var phases: [String: Bool] = [:]
  private var last: Double = 0
  public init() {}

  public mutating func observe(
    _ id: String, running: Bool, now: Double = Date.now.timeIntervalSince1970 * 1000
  ) {
    let previous = phases[id]
    phases[id] = running
    guard previous != running, previous != nil || running else { return }
    last = max(last + 1, now)
    ranks[id] = last
  }

  public mutating func snapshot(
    _ entries: [NavigationEntry], active: Set<String>,
    now: Double = Date.now.timeIntervalSince1970 * 1000
  ) {
    let known = Set(entries.filter { $0.session.time.archived == nil }.map { $0.session.id })
    ranks = ranks.filter { known.contains($0.key) }
    phases = phases.filter { known.contains($0.key) }
    for entry in entries where known.contains(entry.session.id) {
      let baseline =
        entry.session.time.updated == 0 ? entry.session.time.created : entry.session.time.updated
      ranks[entry.session.id] = max(ranks[entry.session.id] ?? baseline, baseline)
      last = max(last, baseline)
    }
    let changed = known.filter { phases[$0] != nil && phases[$0] != active.contains($0) }
    if !changed.isEmpty {
      last = max(last + 1, now)
      changed.forEach { ranks[$0] = last }
    }
    known.forEach { phases[$0] = active.contains($0) }
  }
}
