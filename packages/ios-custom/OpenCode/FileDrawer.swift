import OpenCodeKit
import SwiftUI

/// Arquivos in the viewer (approved mock "opção A", 30/10): the session's folder as the Mac's tree (`FileTree`),
/// with "Filtrar arquivos", `Todos | Alterados`, Recentes and "Buscar em toda a sessão". Opened from the button
/// beside Fechar; a file opens in the viewer and closes the drawer.
@MainActor @Observable final class FileDrawerStore {
  let context: ConversationImageContext
  private(set) var tree: FileTree
  private(set) var statuses: [String: ContextColumn.FileStatus] = [:]
  private(set) var recents: FileRecents
  var filter = ""
  var onlyChanged = false
  /// "Buscar em toda a sessão" (`/api/fs/find`).
  var query = ""
  private(set) var results: [String]?
  private(set) var failure: String?
  @ObservationIgnored private var listing: Set<String> = []
  @ObservationIgnored private var changesLoaded = false

  init(context: ConversationImageContext) {
    self.context = context
    tree = FileTree(root: context.directory)
    recents = FileRecents.load(server: context.client.configuration.url, directory: context.directory, defaults: .standard)
  }

  var rows: [FileTree.Row] { tree.rows(statuses: statuses, onlyChanged: onlyChanged, filter: filter) }
  var listed: Bool { onlyChanged || tree.listings[tree.root] != nil }

  /// The open file with every folder above it expanded: a link from the conversation lands marked in its folder.
  func reveal(_ path: String?) async {
    if let path { tree.reveal(path) }
    await listMissing()
  }

  func toggle(_ folder: String) {
    tree.toggle(folder)
    Task { await listMissing() }
  }

  func record(_ path: String) {
    recents.add(path)
    recents.save(server: context.client.configuration.url, directory: context.directory, defaults: .standard)
  }

  func listMissing() async {
    for folder in tree.unlisted where !listing.contains(folder) {
      listing.insert(folder)
      do {
        tree.store(try await context.client.listDirectory(folder, location: context.directory), in: folder)
        if folder == tree.root { failure = nil }
      } catch {
        if folder == tree.root, !Task.isCancelled {
          failure = if case .http(404) = error as? ClientError { "Esta pasta não existe no servidor." } else {
            error.localizedDescription
          }
        } else {
          tree.store([], in: folder)
        }
      }
      listing.remove(folder)
    }
  }

  /// Working-copy changes, by absolute path (diff paths are relative to the checkout root).
  func loadChanges() async {
    guard !changesLoaded else { return }
    changesLoaded = true
    async let located = try? context.client.locate([context.directory])
    async let working = try? context.client.workingChanges(directory: context.directory)
    let root = await located?.first?.worktree ?? context.directory
    statuses = ContextColumn.statuses(await working ?? [], root: root)
  }

  func find() async {
    let search = query.trimmingCharacters(in: .whitespaces)
    results = nil
    guard !search.isEmpty else { return }
    try? await Task.sleep(for: .milliseconds(200))
    guard !Task.isCancelled else { return }
    results = (try? await context.client.findFiles(search, location: context.directory)) ?? []
  }

  /// `reports`, or the absolute folder outside the session.
  func folder(of path: String) -> String {
    let folder = FileExplorer.parent(path) ?? "/"
    if folder == context.directory { return URL(fileURLWithPath: folder).lastPathComponent }
    return folder.hasPrefix(context.directory + "/") ? String(folder.dropFirst(context.directory.count + 1)) : folder
  }
}

struct FileDrawer: View {
  @Environment(\.appTheme) private var theme
  @Bindable var drawer: FileDrawerStore
  let current: String?
  let open: (String) -> Void
  let close: () -> Void
  @State private var searching = false
  @FocusState private var fieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Arquivos").font(.title2.weight(.bold)).foregroundStyle(theme.color(.textStrong))
            .accessibilityAddTraits(.isHeader)
          Text(URL(fileURLWithPath: drawer.tree.root).lastPathComponent).font(.subheadline)
            .foregroundStyle(theme.color(.textSecondary)).lineLimit(1).truncationMode(.middle)
            .accessibilityIdentifier("file-drawer-root")
        }
        Spacer(minLength: 8)
        Button("Fechar Arquivos", systemImage: "xmark", action: close)
          .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
          .accessibilityIdentifier("file-drawer-close")
      }
      field
      Picker("Mostrar", selection: $drawer.onlyChanged) {
        Text("Todos").tag(false)
        Text("Alterados").tag(true)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("file-drawer-changed")
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if searching { found } else { sections }
          }
          .padding(.bottom, 8)
        }
        .task(id: "\(current ?? ""):\(drawer.rows.contains { $0.id == current })") {
          // After the drawer's first layout, or the lazy stack has nothing to scroll.
          try? await Task.sleep(for: .milliseconds(150))
          if let current, drawer.rows.contains(where: { $0.id == current }) { proxy.scrollTo(current, anchor: .center) }
        }
      }
      Button {
        searching.toggle()
        drawer.query = ""
        fieldFocused = searching
      } label: {
        HStack(spacing: 10) {
          Image(systemName: searching ? "folder" : "magnifyingglass").frame(width: 22)
          Text(searching ? "Voltar à pasta" : "Buscar em toda a sessão")
          Spacer()
          Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(theme.color(.textWeak))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).foregroundStyle(theme.color(.text))
      .accessibilityIdentifier("file-drawer-search")
    }
    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(theme.color(.surface))
    .task(id: drawer.query) { await drawer.find() }
  }

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(theme.color(.textSecondary))
      TextField(searching ? "Buscar em toda a sessão" : "Filtrar arquivos", text: searching ? $drawer.query : $drawer.filter)
        .focused($fieldFocused).autocorrectionDisabled().textInputAutocapitalization(.never)
        .submitLabel(.search)
        .accessibilityIdentifier("file-drawer-filter")
      if !(searching ? drawer.query : drawer.filter).isEmpty {
        Button("Limpar", systemImage: "xmark.circle.fill") { if searching { drawer.query = "" } else { drawer.filter = "" } }
          .labelStyle(.iconOnly).foregroundStyle(theme.color(.textWeak))
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(theme.color(.surfaceRaised), in: Capsule())
  }

  @ViewBuilder private var sections: some View {
    if !drawer.recents.paths.isEmpty && drawer.filter.isEmpty && !drawer.onlyChanged {
      label("RECENTES")
      group {
        ForEach(Array(drawer.recents.paths.prefix(4).enumerated()), id: \.element) { index, path in
          if index > 0 { divider }
          fileButton(path, title: URL(fileURLWithPath: path).lastPathComponent, subtitle: drawer.folder(of: path),
            depth: 0, identifier: "file-drawer-recent-")
        }
      }
      .accessibilityElement(children: .contain).accessibilityIdentifier("file-drawer-recents")
    }
    label("PASTA")
    group {
      let rows = drawer.rows
      if let failure = drawer.failure {
        Text(failure).foregroundStyle(theme.color(.error)).padding(14)
      } else if rows.isEmpty {
        Text(!drawer.listed ? "Carregando…" : !drawer.filter.isEmpty ? "Nenhum arquivo com esse nome."
          : drawer.onlyChanged ? "Nenhum arquivo alterado." : "Pasta vazia")
          .foregroundStyle(theme.color(.textSecondary)).padding(14)
      }
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index > 0 { divider }
        if row.directory {
          Button { drawer.toggle(row.id) } label: {
            line(row.entry.name, subtitle: nil, depth: row.depth, folder: true, open: row.open, path: row.id)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(row.entry.name + ", pasta " + (row.open ? "aberta" : "fechada"))
          .accessibilityIdentifier("file-drawer-row-" + row.entry.name)
          .id(row.id)
        } else {
          fileButton(row.id, title: row.entry.name, subtitle: nil, depth: row.depth, identifier: "file-drawer-row-").id(row.id)
        }
      }
    }
  }

  @ViewBuilder private var found: some View {
    label("RESULTADOS")
    group {
      if let results = drawer.results {
        if results.isEmpty { Text("Nenhum arquivo encontrado").foregroundStyle(theme.color(.textSecondary)).padding(14) }
        ForEach(Array(results.enumerated()), id: \.element) { index, path in
          if index > 0 { divider }
          fileButton(path, title: URL(fileURLWithPath: path).lastPathComponent, subtitle: drawer.folder(of: path),
            depth: 0, identifier: "file-drawer-result-")
        }
      } else if !drawer.query.trimmingCharacters(in: .whitespaces).isEmpty {
        ProgressView().padding(14)
      } else {
        Text("Digite parte do nome de um arquivo.").foregroundStyle(theme.color(.textSecondary)).padding(14)
      }
    }
  }

  private func fileButton(_ path: String, title: String, subtitle: String?, depth: Int, identifier: String) -> some View {
    Button { open(path) } label: {
      line(title, subtitle: subtitle, depth: depth, folder: false, open: false, path: path)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title + (path == current ? ", aberto" : ""))
    .accessibilityAddTraits(path == current ? .isSelected : [])
    .accessibilityIdentifier(identifier + title)
  }

  private func line(_ title: String, subtitle: String?, depth: Int, folder: Bool, open: Bool, path: String) -> some View {
    let marked = !folder && path == current
    let status = drawer.statuses[path]
    return HStack(spacing: 10) {
      if folder {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.color(.textWeak))
          .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
      }
      Image(systemName: folder ? "folder" : "doc").foregroundStyle(theme.color(.icon)).frame(width: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).foregroundStyle(theme.color(.textStrong)).lineLimit(1).truncationMode(.middle)
          .font(marked ? .body.weight(.semibold) : .body)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(theme.color(.textSecondary)).lineLimit(1).truncationMode(.head)
        }
      }
      Spacer(minLength: 6)
      if let status {
        Text(status.deletions > 0 ? "+\(status.additions) −\(status.deletions)" : "+\(status.additions)")
          .font(.caption.monospacedDigit()).foregroundStyle(theme.color(.success))
      } else if folder, ContextColumn.changedFolders(drawer.statuses).contains(path) {
        Circle().fill(theme.color(.textSecondary)).frame(width: 6, height: 6)
      }
    }
    .padding(.leading, 14 + CGFloat(depth) * 16).padding(.trailing, 14).padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.color(.highlight).opacity(marked ? 1 : 0))
    .overlay(alignment: .leading) {
      if marked { Rectangle().fill(theme.color(.primary)).frame(width: 3) }
    }
    .contentShape(Rectangle())
  }

  private func label(_ text: String) -> some View {
    Text(text).font(.footnote.weight(.semibold)).foregroundStyle(theme.color(.textSecondary))
      .padding(.top, 14).padding(.bottom, 6).padding(.leading, 4)
  }

  private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0, content: content)
      .background(theme.color(.surfaceRaised), in: RoundedRectangle(cornerRadius: 14))
      .clipShape(RoundedRectangle(cornerRadius: 14))
  }

  private var divider: some View {
    Rectangle().fill(theme.color(.border)).frame(height: 0.5).padding(.leading, 46)
  }
}
