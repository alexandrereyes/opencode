import Foundation

public enum ProjectRail {
  public struct Item: Identifiable, Sendable, Equatable {
    public let group: ChipGroup
    public let count: Int
    public var id: String { group.key }
  }

  /// Chats is pinned below Todas on the Mac; repositories retain the chips' activity/manual order.
  public static func items(rows: [SessionRow], chips: [ChipEntry], active: Set<String>) -> [Item] {
    let counts = Dictionary(grouping: rows, by: { $0.chat ? ChipManualOrder.chats : $0.project?.id ?? "" })
    let groups = SessionList.chipGroups(rows, chips: chips, chats: ChipManualOrder.chats)
    return (groups.filter { $0.key == ChipManualOrder.chats } + groups.filter { $0.key != ChipManualOrder.chats }).map {
      var group = $0
      let members = counts[group.key] ?? []
      // Pending requests take precedence in row.state, but the working indicator must coexist with them.
      group.running = group.running || members.contains { $0.working || !$0.memberIDs.isDisjoint(with: active) }
      return Item(group: group, count: members.count)
    }
  }

  public static func drop(_ source: String, onto target: String, manual: ChipManualOrder) -> PreferenceIntent? {
    guard source != target, let from = manual.projects.first(where: { $0.id == source }),
      let index = manual.projects.firstIndex(where: { $0.id == target }) else { return nil }
    return .move(directory: from.directory, toIndex: index)
  }
}
