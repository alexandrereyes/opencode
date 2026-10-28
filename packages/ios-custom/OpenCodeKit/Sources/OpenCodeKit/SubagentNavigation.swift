import Foundation

public enum SubagentNavigation {
  /// Only ancestors between the selected root and child; incomplete histories keep their known suffix.
  public static func path(root: String, child: String?, sessions: [Session]) -> [Session] {
    let known = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    var path: [Session] = []
    var next = child
    var seen = Set<String>()
    while let id = next, id != root, seen.insert(id).inserted, let session = known[id] {
      path.append(session)
      next = session.parentID
    }
    return path.reversed()
  }
}
