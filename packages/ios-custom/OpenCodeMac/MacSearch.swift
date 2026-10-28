import Observation
import OpenCodeKit

/// Window-owned interaction state. A, B and C consume the same groups, selection and actions.
@MainActor @Observable final class MacSearch {
  var visible = false
  var query = "" {
    didSet { if query != oldValue { selectedID = nil; expanded = [] } }
  }
  var selectedID: String?
  var expanded: Set<WindowSearch.Kind> = []
  var focusRequest = 0

  func groups(_ store: SessionStore) -> [WindowSearch.Group] {
    WindowSearch.groups(query: query, rows: store.rows, chips: store.selectedProjects.map(\.project),
      archived: store.archived, projects: store.projects, expanded: expanded, label: store.directoryLabel)
  }

  func open() {
    visible = true
    focusRequest += 1
  }

  func selection(_ store: SessionStore) -> String? {
    let ids = choices(store)
    return selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
  }

  func move(_ offset: Int, store: SessionStore) {
    let ids = choices(store)
    guard !ids.isEmpty else { return }
    let index = selection(store).flatMap { ids.firstIndex(of: $0) } ?? 0
    selectedID = ids[min(max(index + offset, 0), ids.count - 1)]
  }

  func choose(_ id: String? = nil, runtime: MacWindowRuntime) {
    guard let store = runtime.store, let id = id ?? selection(store) else { return }
    let groups = groups(store)
    if let group = groups.first(where: { moreID($0.kind) == id }) {
      expanded.insert(group.kind)
      selectedID = self.groups(store).first { $0.kind == group.kind }?.results.dropFirst(group.results.count).first?.id
      return
    }
    guard let result = groups.flatMap(\.results).first(where: { $0.id == id }) else { return }
    switch result.target {
    case .project(let project):
      let next = WindowSearch.projectSelection(project, current: store.selectedProject, filter: store.filter)
      store.selectedProject = next.project
      store.filter = next.filter
      runtime.columns = .all
    case .session(let session):
      if store.rows.contains(where: { $0.id == session }), !store.filtered.contains(where: { $0.id == session }) {
        store.selectedProject = nil
        store.filter = .all
      }
      runtime.sessionSelection.clear()
      runtime.select(session)
    }
    close(runtime: runtime)
  }

  func close(runtime: MacWindowRuntime, focusComposer: Bool = true) {
    visible = false
    guard focusComposer, let id = runtime.selection.childID ?? runtime.selection.sessionID else { return }
    runtime.drafts.draft(id).focused = true
  }

  func moreID(_ kind: WindowSearch.Kind) -> String { "more:" + kind.rawValue }

  private func choices(_ store: SessionStore) -> [String] {
    groups(store).flatMap { $0.results.map(\.id) + ($0.hasMore ? [moreID($0.kind)] : []) }
  }
}
