import Foundation

/// Ordered by precedence: permission > question > running > failed > unread > stopped.
public enum SessionState: Int, Sendable {
  case stopped, unread, failed, running, question, permission
}

public struct SessionRow: Sendable, Identifiable {
  public let entry: NavigationEntry
  public let project: Project?
  public let memberIDs: Set<String>
  public let state: SessionState
  public let unread: Bool
  public let pinned: Bool
  /// "Avisar ao terminar" is on: the server pushes an alert when it finishes.
  public let notify: Bool
  public let activeChildren: Int
  public let requestCount: Int
  public let rank: Double
  /// A managed `custom.chats` conversation: listed in Todas and Chats, never under a repository filter.
  public var chat = false
  public var id: String { entry.session.id }
  public var session: Session { entry.session }
  public var interactionAt: Double { entry.messageAt ?? session.time.created }
  /// A pending permission or question, or an unseen failure: the rows of "Precisa de você".
  public var needsYou: Bool { state == .permission || state == .question || state == .failed }
  public var projectName: String {
    if chat { return session.displayTitle }
    return project?.displayName ?? URL(fileURLWithPath: session.location.directory).lastPathComponent
  }
  /// A chat listed beside repository sessions (every list but the Chats filter) shares one chat avatar and reads
  /// "Chats" as its second line; under the Chats filter each chat keeps its own avatar.
  public func sharesChatAvatar(mixed: Bool) -> Bool { chat && mixed }
}

public enum SessionFilter: String, CaseIterable, Identifiable, Sendable {
  case all = "Todas"
  case unread = "Não lidas"
  case pinned = "Fixadas"
  case running = "Rodando"
  case attention = "Precisa de você"
  public var id: Self { self }
  public func includes(_ row: SessionRow) -> Bool {
    switch self {
    case .all: true
    case .unread: row.unread
    case .pinned: row.pinned
    case .running: row.state == .running
    case .attention: row.needsYou
    }
  }
}

public enum SessionList {
  public static func rows(
    entries: [NavigationEntry], projects: [Project], active: Set<String>,
    pins: [String], notify: [String], autoApprove: Bool,
    ranks: [String: Double], chatRoot: String?
  ) -> [SessionRow] {
    let pinnedIDs = pins.compactMap(SessionPreferenceKey.sessionID)
    let notifyIDs = Set(notify.compactMap(SessionPreferenceKey.sessionID))
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
      // Opening the session (viewed) or running it again clears the failure; an interruption is not one.
      let failed = session.outcome == .failed && (session.time.idle ?? 0) > (session.time.viewed ?? 0)
      return SessionRow(
        entry: entry, project: projects.first { $0.id == session.projectID },
        memberIDs: Set(members.map { $0.session.id }),
        state: permissions > 0
          ? .permission
          : questions > 0
            ? .question : running ? .running : failed ? .failed : unread ? .unread : .stopped,
        unread: unread, pinned: pinnedIDs.contains(session.id),
        notify: notifyIDs.contains(session.id),
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

  /// One pass over the rows for the Sessões filter chips, ordered lexicographically: running chips first, then
  /// chips with unread rows, then the saved manual position, then the name (natural, case- and accent-insensitive,
  /// pt-BR). Chips without a manual position (Chats) follow every positioned chip of their state.
  /// Unread follows the list's orange dot: a root row that is unread.
  public static func chipGroups(_ rows: [SessionRow], chips: [ChipEntry], chats: String) -> [ChipGroup] {
    var groups = Dictionary(uniqueKeysWithValues: chips.map { ($0.key, ChipGroup(key: $0.key)) })
    for row in rows {
      guard let key = row.chat ? chats : row.project?.id, groups[key] != nil else { continue }
      if row.state == .running { groups[key]?.running = true }
      if row.requestCount > 0 { groups[key]?.requests += 1 }
      if row.unread { groups[key]?.unread = true }
    }
    let locale = Locale(identifier: "pt_BR")
    return chips.sorted { left, right in
      let a = groups[left.key]!
      let b = groups[right.key]!
      if a.running != b.running { return a.running }
      if a.unread != b.unread { return a.unread }
      if left.position != right.position { return (left.position ?? .max) < (right.position ?? .max) }
      let names = left.name.compare(
        right.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
      return names == .orderedSame ? left.key < right.key : names == .orderedAscending
    }.map { groups[$0.key]! }
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

/// The saved manual order of the Sessões filter chips: the selected repositories (`projects["local"]`) with Chats
/// inserted after `chatsIndex` of them (absent: Chats first).
public struct ChipManualOrder: Sendable {
  public static let chats = "custom.chats"
  /// Repository chips as (project ID, saved worktree), in saved order.
  public let projects: [(id: String, directory: String)]
  public let chatsIndex: Int?
  public let showsChats: Bool
  public init(projects: [(id: String, directory: String)], chatsIndex: Int?, showsChats: Bool) {
    self.projects = projects
    self.chatsIndex = chatsIndex
    self.showsChats = showsChats
  }
  private var chatsAt: Int { min(max(chatsIndex ?? 0, 0), projects.count) }
  public var keys: [String] {
    var keys = projects.map(\.id)
    if showsChats { keys.insert(Self.chats, at: chatsAt) }
    return keys
  }
  /// The intent that swaps `key` with its previous (`offset` -1) or next (+1) chip in this order, if any.
  public func move(_ key: String, by offset: Int) -> PreferenceIntent? {
    let keys = keys
    guard let from = keys.firstIndex(of: key), keys.indices.contains(from + offset) else { return nil }
    let neighbour = keys[from + offset]
    if key == Self.chats { return .chatsMove(toIndex: chatsAt + offset) }
    // Passing Chats moves Chats the other way; the repositories keep their saved order.
    if neighbour == Self.chats { return .chatsMove(toIndex: chatsAt - offset) }
    guard let index = projects.firstIndex(where: { $0.id == key }) else { return nil }
    return .move(directory: projects[index].directory, toIndex: index + offset)
  }
}

/// A filter chip before its rows are counted: `position` is its index in the saved manual order, if any.
public struct ChipEntry: Sendable, Equatable {
  public let key: String
  public let name: String
  public let position: Int?
  public init(key: String, name: String, position: Int?) {
    self.key = key
    self.name = name
    self.position = position
  }
}

public struct ChipGroup: Sendable, Equatable {
  public let key: String
  public var running = false
  /// Rows needing a permission or answer.
  public var requests = 0
  public var unread = false
  public init(key: String, running: Bool = false, requests: Int = 0, unread: Bool = false) {
    self.key = key
    self.running = running
    self.requests = requests
    self.unread = unread
  }
}
