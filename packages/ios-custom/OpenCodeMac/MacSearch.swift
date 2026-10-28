import Foundation
import Observation
import OpenCodeKit

/// Window-owned interaction state: query, keyboard selection and actions over one catalog of the store.
@MainActor @Observable final class MacSearch {
  var visible = false {
    didSet { if visible && !oldValue { prepare() } }
  }
  var query = "" {
    didSet {
      guard query != oldValue else { return }
      selectedID = nil
      expanded = []
      filter()
    }
  }
  var selectedID: String?
  private(set) var expanded: Set<WindowSearch.Kind> = []
  var focusRequest = 0
  /// The current query's results; a keystroke only refilters the catalog's folded index.
  private(set) var groups: [WindowSearch.Group] = []
  private(set) var catalog: Catalog?
  @ObservationIgnored private let store: () -> SessionStore?
  @ObservationIgnored private var stale = true

  init(store: @escaping () -> SessionStore?) {
    self.store = store
  }

  /// Everything one opening reads from the store, computed once: `SessionStore.rows` is derived on each access.
  struct Catalog {
    let index: WindowSearch.Index
    let rows: [String: SessionRow]
    let archived: [String: Session]
    let projects: [String: Project]
    let labels: [String: SessionDirectoryLabel]
    /// Root sessions per project ID, `WindowSearch.chats` and "" for Todas.
    let counts: [String: Int]
    let running: Set<String>

    @MainActor init(_ store: SessionStore) {
      let rows = store.rows
      let roots = rows.filter { $0.session.parentID == nil && $0.session.time.archived == nil }
      var labels: [String: SessionDirectoryLabel] = [:]
      index = WindowSearch.Index(rows: rows, chips: store.selectedProjects.map(\.project), archived: store.archived,
        projects: store.projects, label: { session in
          let label = store.directoryLabel(session)
          labels[session.id] = label
          return label
        })
      self.labels = labels
      self.rows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      archived = Dictionary(store.archived.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      projects = Dictionary(store.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var counts = ["": roots.count]
      for row in roots {
        let key = row.chat ? WindowSearch.chats : row.project?.id ?? ""
        if !key.isEmpty { counts[key, default: 0] += 1 }
      }
      self.counts = counts
      running = Set(rows.filter { store.active.contains($0.id) || $0.state == .running }.map(\.id))
    }

    func session(_ id: String) -> Session? { rows[id]?.session ?? archived[id] }
  }

  func open() {
    visible = true
    focusRequest += 1
  }

  /// Rebuilds the catalog when the store changed since the last opening, and while the list is open.
  func prepare() {
    guard stale || catalog == nil, let store = store() else { return }
    stale = false
    #if DEBUG
    let start = ProcessInfo.processInfo.systemUptime
    defer { MacSearchTrace.log(String(format: "catálogo %d sessões %.1f ms", catalog?.rows.count ?? 0,
      (ProcessInfo.processInfo.systemUptime - start) * 1000)) }
    #endif
    catalog = withObservationTracking { Catalog(store) } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.stale = true
        if self.visible { self.prepare() }
      }
    }
    filter()
  }

  var selection: String? {
    let ids = choices
    return selectedID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
  }

  func move(_ offset: Int) {
    let ids = choices
    guard !ids.isEmpty else { return }
    let index = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
    selectedID = ids[min(max(index + offset, 0), ids.count - 1)]
    #if DEBUG
    MacSearchTrace.log("seleção " + (selectedID ?? "-"))
    #endif
  }

  func choose(_ id: String? = nil, runtime: MacWindowRuntime) {
    guard let store = runtime.store, let id = id ?? selection else { return }
    if let group = groups.first(where: { moreID($0.kind) == id }) {
      expanded.insert(group.kind)
      filter()
      selectedID = groups.first { $0.kind == group.kind }?.results.dropFirst(group.results.count).first?.id
      return
    }
    guard let result = groups.flatMap(\.results).first(where: { $0.id == id }) else { return }
    #if DEBUG
    MacSearchTrace.log("abriu " + id)
    #endif
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
      #if DEBUG
      MacSearchTrace.log("janela mostra " + (runtime.selection.childID ?? runtime.selection.sessionID ?? "-"))
      #endif
    }
    close(runtime: runtime)
  }

  func close(runtime: MacWindowRuntime, focusComposer: Bool = true) {
    #if DEBUG
    if visible { MacSearchTrace.log("fechou") }
    #endif
    visible = false
    guard focusComposer, let id = runtime.selection.childID ?? runtime.selection.sessionID else { return }
    runtime.drafts.draft(id).focused = true
  }

  func moreID(_ kind: WindowSearch.Kind) -> String { "more:" + kind.rawValue }

  private func filter() {
    groups = catalog?.index.groups(query: query, expanded: expanded) ?? []
  }

  private var choices: [String] {
    groups.flatMap { $0.results.map(\.id) + ($0.hasMore ? [moreID($0.kind)] : []) }
  }
}
