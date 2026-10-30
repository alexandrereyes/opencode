import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// Arquivos, over the Contexto column: the session's checkout as a tree (`/api/fs/list`, `FileTree`, shared with
/// the iPhone's drawer) with working-copy changes on the left and the open file on the right.
struct MacFilesView: View {
  @Environment(\.appTheme) private var theme
  let context: ContextColumnStore
  @Bindable var runtime: MacWindowRuntime
  @State private var files: MacFilesStore?

  var body: some View {
    Group {
      if let files { MacFilesContent(files: files, runtime: runtime) } else { Color.clear }
    }
    // Opened at launch, Arquivos can appear before the session (and its directory) has loaded.
    .task(id: context.directory) {
      guard context.directory != nil else { return }
      let store = MacFilesStore(context: context)
      files = store
      #if DEBUG
      MacFilesStore.shown = store
      #endif
      await store.open(folder: runtime.selection.files?.folder, file: runtime.selection.files?.file)
    }
    .onChange(of: runtime.selection.files) { _, next in
      guard let files, let next, next.folder != nil || next.file != nil,
        next.folder != files.folder || next.file != files.selected else { return }
      Task { await files.open(folder: next.folder, file: next.file) }
    }
  }
}

/// `‹ Contexto`, the title, Ampliar and search; the absolute path; then the tree beside the open file. A narrow
/// panel (or the tree hidden by hand) folds the tree into a thin rail that opens it over the file.
private struct MacFilesContent: View {
  @Environment(\.appTheme) private var theme
  @Bindable var files: MacFilesStore
  @Bindable var runtime: MacWindowRuntime
  @State private var searching = false
  @FocusState private var searchFocused: Bool
  @AppStorage("OpenCodeMacFilesTreeWidth") private var treeWidth = 260.0
  @AppStorage("OpenCodeMacFilesTreeHidden") private var treeHidden = false
  @State private var width: CGFloat = 0
  /// The tree over the file, from the rail.
  @State private var floating = false

  /// Below this the tree and the file's actions no longer fit beside each other.
  static let narrowWidth: CGFloat = 620
  private var narrow: Bool { width > 0 && width < Self.narrowWidth }
  private var folded: Bool { narrow || treeHidden }
  private var treeRange: ClosedRange<Double> { 180...max(180, min(420, Double(width) * 0.5)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        header.padding(.top, 8).padding(.bottom, 8)
        if searching {
          TextField("Buscar arquivos na sessão", text: $files.query)
            .textFieldStyle(.roundedBorder).focused($searchFocused)
            .accessibilityIdentifier("files-search")
        } else {
          breadcrumb
        }
      }
      .padding(.horizontal, 18)
      ContextHairline().padding(.top, 10)
      HStack(spacing: 0) {
        if folded {
          rail
          Rectangle().fill(theme.color(.border)).frame(width: 1)
        } else {
          MacFilesTree(files: files, searching: searching && !files.query.isEmpty, hide: { treeHidden = true })
            .frame(width: min(max(treeWidth, treeRange.lowerBound), treeRange.upperBound))
          MacColumnDivider(width: $treeWidth, range: treeRange, leading: true) { _ in }
        }
        MacFilePane(files: files, compact: narrow)
      }
      .overlay(alignment: .topLeading) {
        if folded && floating {
          MacFilesTree(files: files, searching: searching && !files.query.isEmpty, hide: nil)
            .frame(width: min(300, max(220, width - 80)))
            .frame(maxHeight: .infinity)
            .background(theme.color(.surfaceRaised))
            .overlay(alignment: .trailing) { Rectangle().fill(theme.color(.border)).frame(width: 1) }
            .shadow(color: .black.opacity(0.25), radius: 12, x: 4)
            .padding(.leading, 35)
            .accessibilityIdentifier("files-tree-floating")
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .task(id: files.query) { await files.find() }
    .onChange(of: files.folder) { _, folder in runtime.selection.files?.folder = folder }
    .onChange(of: files.selected) { _, file in
      runtime.selection.files?.file = file
      floating = false
    }
    .onChange(of: folded, initial: true) {
      files.folded = folded
      if !folded { floating = false }
    }
  }

  private var header: some View {
    ZStack {
      HStack {
        Button {
          runtime.selection.files = nil
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            Text("Contexto")
          }
          .appFont(.secondary).foregroundStyle(theme.color(.text)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .keyboardShortcut(.cancelAction)
        .help("Voltar ao contexto (Esc)")
        Spacer()
        Button { runtime.toggleFilesWide() } label: {
          Image(systemName: runtime.filesWide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12)).foregroundStyle(theme.color(.text))
            .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shortcut(.widenFiles)
        .help(runtime.filesWide ? "Reduzir painel (⇧⌘E)" : "Ampliar painel para leitura (⇧⌘E)")
        .accessibilityLabel(runtime.filesWide ? "Reduzir painel" : "Ampliar painel")
        .accessibilityIdentifier("files-widen")
        Button {
          searching.toggle()
          if searching { searchFocused = true } else { files.query = "" }
        } label: {
          Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.color(.text))
            .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Buscar em toda a sessão").accessibilityLabel("Buscar arquivos")
      }
      Text("Arquivos").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.color(.textStrong))
        .accessibilityAddTraits(.isHeader)
    }
  }

  /// The tree folded: show it over the file (or back beside it, when hidden by hand) and search.
  private var rail: some View {
    VStack(spacing: 6) {
      railButton("sidebar.left", label: floating ? "Ocultar a árvore" : "Mostrar a árvore", identifier: "files-tree-toggle") {
        if narrow { floating.toggle() } else { treeHidden = false }
      }
      railButton("magnifyingglass", label: "Buscar em toda a sessão", identifier: "files-rail-search") {
        searching = true
        searchFocused = true
        floating = true
      }
      Spacer()
    }
    .padding(.top, 10)
    .frame(width: 34)
  }

  private func railButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(theme.color(.icon))
        .frame(width: 26, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
  }

  /// The folder's absolute path from `/`, every part clickable. A path that does not fit loses its middle parts
  /// (`/ › … › hidden-pixel › android`); the whole path is the tooltip, and the copy button copies it.
  private var breadcrumb: some View {
    let crumbs = ContextColumn.absoluteBreadcrumb(files.folder)
    return HStack(spacing: 8) {
      ViewThatFits(in: .horizontal) {
        ForEach(Array(stride(from: crumbs.count, through: 1, by: -1)), id: \.self) { keep in
          crumbLine(ContextColumn.middleElided(crumbs, keep: keep), last: crumbs.last?.path)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(files.folder)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.folder, forType: .string)
        files.context.sessions.toast.show("Caminho copiado")
      } label: {
        Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
          .frame(width: 20, height: 18).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Copiar caminho")
      .accessibilityLabel("Copiar caminho")
    }
    .appFont(.footnote)
  }

  private func crumbLine(_ crumbs: [ContextColumn.Crumb?], last: String?) -> some View {
    HStack(spacing: 5) {
      ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
        if index > 0 {
          Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(theme.color(.textWeak))
        }
        if let crumb {
          Button(crumb.name) { Task { await files.open(folder: crumb.path, file: nil) } }
            .buttonStyle(.plain)
            .foregroundStyle(theme.color(crumb.path == last ? .text : .textSecondary))
            .help(crumb.path)
        } else {
          Text("…").foregroundStyle(theme.color(.textSecondary))
        }
      }
    }
    .lineLimit(1).fixedSize()
  }
}

/// "Filtrar arquivos", `Todos · Alterados` and the tree: disclosure chevrons, monochrome icons, `+N −N` and a dot on
/// folders holding changes; the open file marked with the primary color. ↑ ↓ move, → opens a folder and ← closes
/// it (or goes to its folder) while the tree has the focus.
struct MacFilesTree: View {
  @Environment(\.appTheme) private var theme
  @Bindable var files: MacFilesStore
  /// Server-wide search results replace the tree.
  let searching: Bool
  /// The button that hides the tree beside the file; none over it.
  let hide: (() -> Void)?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { field; filters.fixedSize() }
        VStack(alignment: .leading, spacing: 6) { field; filters }
      }
      .padding(.horizontal, 10).padding(.top, 10)
      list
      if let hide {
        Button(action: hide) {
          Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(theme.color(.icon))
            .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Ocultar a árvore").accessibilityLabel("Ocultar a árvore")
        .padding(.leading, 8).padding(.bottom, 8)
      }
    }
  }

  private var field: some View {
    HStack(spacing: 6) {
      Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(theme.color(.textSecondary))
      TextField("Filtrar arquivos", text: $files.filter).textFieldStyle(.plain).appFont(.caption)
        .accessibilityIdentifier("files-filter")
      if !files.filter.isEmpty {
        Button { files.filter = "" } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(theme.color(.textWeak))
        }
        .buttonStyle(.plain).accessibilityLabel("Limpar filtro")
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 7))
    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(theme.color(.controlBorder), lineWidth: 0.5) }
    .frame(minWidth: 120)
  }

  private var filters: some View {
    HStack(spacing: 5) {
      choice("Todos", selected: !files.onlyChanged) { files.onlyChanged = false }
      Text("·").foregroundStyle(theme.color(.textWeak))
      choice("Alterados", selected: files.onlyChanged) { files.onlyChanged = true }
    }
    .appFont(.caption)
  }

  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .buttonStyle(.plain)
      .fontWeight(selected ? .semibold : .regular)
      .foregroundStyle(theme.color(selected ? .textStrong : .textSecondary))
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityIdentifier("files-" + title.lowercased())
      .help(title == "Alterados" ? "Só os arquivos alterados e as pastas que os contêm" : "Todos os arquivos")
  }

  private var list: some View {
    Group {
      if let failure = files.failure {
        VStack(spacing: 10) {
          Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.textSecondary))
          Button("Tentar novamente") { Task { await files.reload() } }
        }
        .appFont(.caption).padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        let rows = files.rows
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 1) {
              ForEach(rows) { row in
                MacFileLine(row: row, open: row.id == files.selected, cursor: focused && row.id == files.cursor) {
                  files.activate(row)
                  focused = true
                }
                .id(row.id)
              }
            }
            .padding(.horizontal, 6).padding(.bottom, 8)
            .macThinScrollers()
          }
          // A file opened from a link, Recentes or the history shows in the tree once its folders are listed.
          .task(id: "\(files.selected ?? ""):\(rows.contains { $0.id == files.selected })") {
            if let selected = files.selected, rows.contains(where: { $0.id == selected }) {
              proxy.scrollTo(selected, anchor: .center)
            }
          }
          .onChange(of: files.cursor) { _, cursor in if let cursor { proxy.scrollTo(cursor) } }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { files.moveCursor(-1) ? .handled : .ignored }
        .onKeyPress(.downArrow) { files.moveCursor(1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { files.openCursor(true) ? .handled : .ignored }
        .onKeyPress(.leftArrow) { files.openCursor(false) ? .handled : .ignored }
        .overlay {
          if rows.isEmpty {
            Text(!files.listed ? "Carregando…"
              : !files.filter.trimmingCharacters(in: .whitespaces).isEmpty ? "Nenhum arquivo com esse nome."
              : files.onlyChanged ? "Nenhum arquivo alterado aqui." : "Pasta vazia")
              .appFont(.caption).foregroundStyle(theme.color(.textSecondary)).padding(12)
          }
        }
        .accessibilityIdentifier("files-tree")
      }
    }
  }
}

/// One entry of the tree: the disclosure chevron of a folder, a monochrome icon, the name and, for a changed file,
/// `+N −N`; a folder holding changes shows a gray dot.
private struct MacFileLine: View {
  @Environment(\.appTheme) private var theme
  let row: MacFileRow
  let open: Bool
  let cursor: Bool
  let activate: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 6) {
        Group {
          if row.directory {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
              .rotationEffect(.degrees(row.open ? 90 : 0))
              .foregroundStyle(theme.color(.textWeak))
          }
        }
        .frame(width: 12)
        Image(systemName: row.directory ? "folder" : "doc").font(.system(size: 13))
          .foregroundStyle(theme.color(.icon)).frame(width: 16)
        Text(row.title).appFont(.secondary).foregroundStyle(theme.color(.textStrong))
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 6)
        if let status = row.status {
          HStack(spacing: 6) {
            if status.additions > 0 || status.change == .added {
              Text("+\(status.additions)").foregroundStyle(theme.color(.success))
            }
            if status.deletions > 0 || status.change == .deleted {
              Text("−\(status.deletions)").foregroundStyle(theme.color(.error))
            }
          }
          .appFont(.caption).monospacedDigit()
        } else if row.containsChanges {
          Circle().fill(theme.color(.textSecondary)).frame(width: 5, height: 5)
            .help("Contém arquivos alterados")
        }
      }
      .padding(.leading, 4 + CGFloat(row.depth) * 14).padding(.trailing, 8).padding(.vertical, 6)
      .background(theme.color(.highlight).opacity(open ? 1 : cursor ? 0.7 : hovering ? 0.5 : 0),
        in: RoundedRectangle(cornerRadius: 6))
      .overlay(alignment: .leading) {
        if open { RoundedRectangle(cornerRadius: 1).fill(theme.color(.primary)).frame(width: 3).padding(.vertical, 3) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(details)
    .contextMenu {
      if FileManager.default.fileExists(atPath: row.id) {
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)]) }
      }
      Button("Copiar caminho") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.id, forType: .string)
      }
    }
    .accessibilityLabel(row.directory ? "\(row.title), pasta \(row.open ? "aberta" : "fechada")" : row.title)
    .accessibilityAddTraits(open ? .isSelected : [])
    .accessibilityIdentifier("files-row-" + row.title)
  }

  /// Date and size, read from this Mac when the checkout is local.
  private var details: String {
    [
      row.modified.map { "Modificado " + $0.formatted(.dateTime.day().month(.twoDigits).hour().minute()) },
      row.size.map { $0.formatted(.byteCount(style: .file)) },
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

struct MacFileRow: Identifiable {
  let id: String
  let name: String
  /// The name, or the path relative to the session for search results.
  let title: String
  let directory: Bool
  let depth: Int
  let open: Bool
  let modified: Date?
  let size: Int64?
  let status: ContextColumn.FileStatus?
  let containsChanges: Bool
}

@MainActor @Observable final class MacFilesStore {
  let context: ContextColumnStore
  private(set) var tree: FileTree
  /// The breadcrumb's folder: the open file's, or the folder last opened.
  private(set) var folder: String
  private(set) var failure: String?
  private(set) var results: [String]?
  /// Searches the whole session on the server (the magnifier).
  var query = ""
  /// Filters the tree's listed names.
  var filter = ""
  var onlyChanged = false
  private(set) var selected: String?
  private(set) var file: MacLoadedFile?
  private(set) var history = FileHistory()
  private(set) var recents: FileRecents
  /// The row the arrow keys move from: the open file or a folder.
  private(set) var cursor: String?
  @ObservationIgnored private var listing: Set<String> = []
  /// Whether the panel folded the tree into its rail, for the checks.
  @ObservationIgnored var folded = false
  #if DEBUG
  /// The panel on screen, for `MacAjustesChecks`.
  @ObservationIgnored static weak var shown: MacFilesStore?
  #endif

  init(context: ContextColumnStore) {
    self.context = context
    let root = context.directory ?? context.root
    tree = FileTree(root: root)
    folder = root
    recents = FileRecents.load(server: context.client.configuration.url, directory: root, defaults: .standard)
  }

  /// Whether the top folder (or Alterados, which needs no listing) can be drawn.
  var listed: Bool { onlyChanged || tree.listings[tree.root] != nil }

  private var searchActive: Bool { results != nil && !query.trimmingCharacters(in: .whitespaces).isEmpty }

  var rows: [MacFileRow] {
    let statuses = context.statuses
    let folders = ContextColumn.changedFolders(statuses)
    if let results, searchActive {
      return results.filter { !onlyChanged || statuses[$0] != nil }.map { path in
        row(DirectoryEntry(name: URL(fileURLWithPath: path).lastPathComponent, absolute: path, kind: .file),
          title: relative(path), depth: 0, open: false, statuses: statuses, folders: folders)
      }
    }
    return tree.rows(statuses: statuses, onlyChanged: onlyChanged, filter: filter).map {
      row($0.entry, title: $0.entry.name, depth: $0.depth, open: $0.open, statuses: statuses, folders: folders)
    }
  }

  /// A link opens its file with every folder above it expanded; a folder (the breadcrumb, a folder link) opens
  /// expanded and becomes the breadcrumb's folder.
  func open(folder: String?, file: String?) async {
    if let file {
      select(file)
    } else if let folder {
      tree.reveal(folder, directory: true)
      self.folder = folder
    }
    await listMissing()
  }

  func reload() async {
    failure = nil
    await listMissing()
  }

  /// Lists the folders the tree shows open, top first.
  func listMissing() async {
    for folder in tree.unlisted where !listing.contains(folder) {
      await list(folder)
    }
  }

  private func list(_ folder: String) async {
    guard let directory = context.directory else { return }
    listing.insert(folder)
    defer { listing.remove(folder) }
    do {
      tree.store(try await context.client.listDirectory(folder, location: directory), in: folder)
      if folder == tree.root { failure = nil }
    } catch {
      if Task.isCancelled { return }
      guard folder == tree.root else {
        tree.store([], in: folder)
        return
      }
      failure = switch error as? ClientError {
      case .http(404): "Esta pasta não existe no servidor."
      case .http(500): "Não foi possível ler esta pasta. Verifique as permissões dela no servidor."
      default: error.localizedDescription
      }
    }
  }

  func find() async {
    let search = query.trimmingCharacters(in: .whitespaces)
    results = nil
    guard !search.isEmpty, let directory = context.directory else { return }
    try? await Task.sleep(for: .milliseconds(180))
    guard !Task.isCancelled else { return }
    results = (try? await context.client.findFiles(search, location: directory)) ?? []
  }

  func activate(_ row: MacFileRow) {
    cursor = row.id
    if row.directory {
      toggle(row.id)
    } else {
      select(row.id)
    }
  }

  func toggle(_ folder: String) {
    tree.toggle(folder)
    Task { await listMissing() }
  }

  /// Opens a file in the pane. `record` false is ‹ and ›, which walk the history instead of adding to it.
  func select(_ path: String, record: Bool = true) {
    cursor = path
    folder = FileExplorer.parent(path) ?? "/"
    if record {
      history.visit(path)
      recents.add(path)
      if let directory = context.directory {
        recents.save(server: context.client.configuration.url, directory: directory, defaults: .standard)
      }
    }
    if !tree.reveal(path).isEmpty { Task { await listMissing() } }
    guard path != selected || file == nil else { return }
    selected = path
    file = nil
    Task {
      let loaded = await MacLoadedFile.load(path, client: context.client)
      if selected == path { file = loaded }
    }
  }

  func back() {
    if let path = history.goBack() { select(path, record: false) }
  }

  func forward() {
    if let path = history.goForward() { select(path, record: false) }
  }

  /// The file `offset` places before or after the open one in its folder, as the tree shows it (⌥⌘← ⌥⌘→).
  func sibling(_ offset: Int) -> String? {
    guard let selected, !searchActive else { return nil }
    let parent = FileExplorer.parent(selected)
    let files = rows.filter { !$0.directory && FileExplorer.parent($0.id) == parent }.map(\.id)
    guard let index = files.firstIndex(of: selected), files.indices.contains(index + offset) else { return nil }
    return files[index + offset]
  }

  func step(_ offset: Int) {
    if let next = sibling(offset) { select(next) }
  }

  /// ↑ ↓ in the tree: a file opens as the cursor reaches it.
  func moveCursor(_ offset: Int) -> Bool {
    let rows = rows
    guard !rows.isEmpty else { return false }
    let index = rows.firstIndex { $0.id == (cursor ?? selected) }.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
    guard rows.indices.contains(index) else { return true }
    let row = rows[index]
    if row.directory { cursor = row.id } else { select(row.id) }
    return true
  }

  /// → opens the folder under the cursor; ← closes it, or moves to the folder of a file or a closed folder.
  func openCursor(_ open: Bool) -> Bool {
    guard let id = cursor ?? selected, let row = rows.first(where: { $0.id == id }) else { return false }
    if row.directory && row.open != open && !(onlyChanged || !filter.isEmpty) {
      tree.setExpanded(id, open)
      Task { await listMissing() }
    } else if !open, let parent = FileExplorer.parent(id), rows.contains(where: { $0.id == parent }) {
      cursor = parent
    }
    return true
  }

  private func relative(_ path: String) -> String {
    guard let directory = context.directory, path.hasPrefix(directory + "/") else { return path }
    return String(path.dropFirst(directory.count + 1))
  }

  private func row(
    _ entry: DirectoryEntry, title: String, depth: Int, open: Bool, statuses: [String: ContextColumn.FileStatus],
    folders: Set<String>
  ) -> MacFileRow {
    // The server lists names only; dates and sizes come from this Mac when the checkout is local.
    let attributes = try? FileManager.default.attributesOfItem(atPath: entry.absolute)
    return MacFileRow(
      id: entry.absolute, name: entry.name, title: title, directory: entry.kind == .directory, depth: depth, open: open,
      modified: attributes?[.modificationDate] as? Date,
      size: entry.kind == .directory ? nil : (attributes?[.size] as? NSNumber)?.int64Value,
      status: statuses[entry.absolute], containsChanges: folders.contains(entry.absolute))
  }
}

/// A file ready to show: read from this Mac when the path exists here, otherwise downloaded from the server
/// (`FileTransfer`, like the iPhone viewer).
struct MacLoadedFile: Equatable {
  let path: String
  let url: URL
  let text: String?
  let local: Bool
  var error: String?

  static let textLimit = 2 * 1024 * 1024

  static func load(_ path: String, client: OpenCodeClient) async -> MacLoadedFile {
    if FileManager.default.isReadableFile(atPath: path) {
      let url = URL(fileURLWithPath: path)
      return MacLoadedFile(path: path, url: url, text: await text(url), local: true)
    }
    do {
      let downloaded = try await FileTransfer().download(client.fileRequest(path: path)) { _, _ in }
      let stored = try FilePreviewStorage.store(downloaded, name: URL(fileURLWithPath: path).lastPathComponent)
      return MacLoadedFile(path: path, url: stored, text: await text(stored), local: false)
    } catch {
      return MacLoadedFile(path: path, url: URL(fileURLWithPath: path), text: nil, local: false,
        error: FileTransferFailure.map(error).localizedDescription)
    }
  }

  /// Text is drawn in-process up to 2 MB; images, PDFs and binaries go to Quick Look.
  private static func text(_ url: URL) async -> String? {
    await Task.detached {
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
      guard size <= textLimit, let data = try? Data(contentsOf: url),
        !data.prefix(4096).contains(0), let text = String(data: data, encoding: .utf8)
      else { return nil }
      return text
    }.value
  }
}
