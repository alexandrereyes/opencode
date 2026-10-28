import AppKit
import Observation
import OpenCodeKit
import SwiftUI

/// Arquivos, over the Contexto column: the session's checkout as a Finder-like list (`/api/fs/list`, like the
/// iPhone explorer) with working-copy changes, and the selected file below it.
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
      await store.open(folder: runtime.selection.files?.folder, file: runtime.selection.files?.file)
    }
    .onChange(of: runtime.selection.files) { _, next in
      guard let files, let next, next.folder != nil || next.file != nil,
        next.folder != files.folder || next.file != files.selected else { return }
      Task { await files.open(folder: next.folder, file: next.file) }
    }
  }
}

/// Arquivos at the "Máximo" level: `‹ Contexto`, the title and search; a gray breadcrumb; `PASTA` with
/// `Todos · Alterados`; a Finder-like list with monochrome icons and colored `+N −N`; the selected file below.
private struct MacFilesContent: View {
  @Environment(\.appTheme) private var theme
  @Bindable var files: MacFilesStore
  @Bindable var runtime: MacWindowRuntime
  @State private var searching = false
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.top, 8).padding(.bottom, 8)
      if searching {
        TextField("Buscar arquivos na sessão", text: $files.query)
          .textFieldStyle(.roundedBorder).focused($searchFocused)
      } else {
        breadcrumb
      }
      ContextHairline().padding(.top, 10)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(searching && !files.query.isEmpty ? "RESULTADOS" : "PASTA")
          .font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(theme.color(.text))
        Spacer(minLength: 8)
        filter("Todos", selected: !files.onlyChanged) { files.onlyChanged = false }
        Text("·").foregroundStyle(theme.color(.textWeak))
        filter("Alterados", selected: files.onlyChanged) { files.onlyChanged = true }
      }
      .appFont(.caption)
      .padding(.vertical, 10)
      VSplitView {
        list.frame(minHeight: 120, idealHeight: 300)
        MacFilePane(files: files).frame(minHeight: 180, idealHeight: 420)
      }
    }
    .padding(.horizontal, 18)
    .task(id: files.query) { await files.find() }
    .onChange(of: files.folder) { _, folder in runtime.selection.files?.folder = folder }
    .onChange(of: files.selected) { _, file in runtime.selection.files?.file = file }
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
        Button {
          searching.toggle()
          if searching { searchFocused = true } else { files.query = "" }
        } label: {
          Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.color(.text))
            .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Buscar arquivos").accessibilityLabel("Buscar arquivos")
      }
      Text("Arquivos").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.color(.textStrong))
        .accessibilityAddTraits(.isHeader)
    }
  }

  private func filter(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .buttonStyle(.plain)
      .fontWeight(selected ? .semibold : .regular)
      .foregroundStyle(theme.color(selected ? .textStrong : .textSecondary))
      .accessibilityAddTraits(selected ? .isSelected : [])
      .help(title == "Alterados" ? "Só os arquivos alterados e as pastas que os contêm" : "Todos os arquivos da pasta")
  }

  private var breadcrumb: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 5) {
        let crumbs = ContextColumn.breadcrumb(files.folder, root: files.context.root)
        ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
          if index > 0 {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
              .foregroundStyle(theme.color(.textWeak))
          }
          Button(crumb.name) { Task { await files.open(folder: crumb.path, file: nil) } }
            .buttonStyle(.plain)
            .foregroundStyle(theme.color(index == crumbs.count - 1 ? .text : .textSecondary))
        }
      }
      .appFont(.footnote)
    }
    .scrollIndicators(.never)
    // The current folder is the end of the path: keep it in view.
    .defaultScrollAnchor(.trailing)
  }

  private var list: some View {
    Group {
      if let failure = files.failure {
        VStack(spacing: 10) {
          Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(theme.color(.textSecondary))
          Button("Tentar novamente") { Task { await files.load() } }
        }
        .appFont(.caption)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(files.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { ContextHairline().padding(.leading, 34) }
                MacFileLine(row: row, selected: row.id == files.selected) { files.activate(row.id) }
                  .id(row.id)
              }
            }
            .padding(.bottom, 8)
          }
          .onAppear { if let selected = files.selected { proxy.scrollTo(selected, anchor: .center) } }
        }
        .overlay {
          if files.rows.isEmpty {
            Text(files.entries == nil && files.results == nil ? "Carregando…"
              : files.onlyChanged ? "Nenhum arquivo alterado aqui." : "Pasta vazia")
              .appFont(.caption).foregroundStyle(theme.color(.textSecondary))
          }
        }
      }
    }
  }
}

/// One entry of the list: a monochrome icon, the name and, for a changed file, `+N −N`; a folder holding
/// changes shows a gray dot and every folder a chevron.
private struct MacFileLine: View {
  @Environment(\.appTheme) private var theme
  let row: MacFileRow
  let selected: Bool
  let activate: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 10) {
        Image(systemName: row.directory ? "folder" : "doc").font(.system(size: 14))
          .foregroundStyle(theme.color(.icon)).frame(width: 18)
        Text(row.title).appFont(.secondary).foregroundStyle(theme.color(.textStrong))
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 8)
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
        if row.directory {
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.color(.textWeak))
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 8)
      .background(theme.color(.highlight).opacity(selected ? 1 : hovering ? 0.5 : 0), in: RoundedRectangle(cornerRadius: 7))
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
    .accessibilityAddTraits(selected ? .isSelected : [])
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
  let modified: Date?
  let size: Int64?
  let status: ContextColumn.FileStatus?
  let containsChanges: Bool
}

@MainActor @Observable final class MacFilesStore {
  let context: ContextColumnStore
  private(set) var folder = "/"
  private(set) var entries: [DirectoryEntry]?
  private(set) var failure: String?
  private(set) var results: [String]?
  var query = ""
  var onlyChanged = false
  var selected: String?
  private(set) var file: MacLoadedFile?

  init(context: ContextColumnStore) { self.context = context }

  var rows: [MacFileRow] {
    let statuses = context.statuses
    let folders = ContextColumn.changedFolders(statuses)
    if let results, !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return results.filter { !onlyChanged || statuses[$0] != nil }.map { path in
        row(DirectoryEntry(name: URL(fileURLWithPath: path).lastPathComponent, absolute: path, kind: .file),
          title: relative(path), statuses: statuses, folders: folders)
      }
    }
    return ContextColumn.entries(entries ?? [], statuses: statuses, onlyChanged: onlyChanged, order: .ascending)
      .map { row($0, title: $0.name, statuses: statuses, folders: folders) }
  }

  func open(folder: String?, file: String?) async {
    let target = folder ?? file.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
      ?? context.directory ?? context.root
    if target != self.folder || entries == nil {
      self.folder = target
      entries = nil
      await load()
    }
    if let file { select(file) }
  }

  func load() async {
    guard let directory = context.directory else { return }
    do {
      entries = try await context.client.listDirectory(folder, location: directory)
      failure = nil
    } catch {
      if Task.isCancelled { return }
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

  func activate(_ id: String) {
    if rows.first(where: { $0.id == id })?.directory == true {
      Task { await open(folder: id, file: nil) }
    } else {
      select(id)
    }
  }

  /// The file `offset` places before or after the selected one in the folder's listing (files only).
  func sibling(_ offset: Int) -> String? {
    guard let selected, results == nil || query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let files = rows.filter { !$0.directory }.map(\.id)
    guard let index = files.firstIndex(of: selected), files.indices.contains(index + offset) else { return nil }
    return files[index + offset]
  }

  func step(_ offset: Int) {
    if let next = sibling(offset) { select(next) }
  }

  func select(_ path: String) {
    guard path != selected || file == nil else { return }
    selected = path
    file = nil
    Task {
      let loaded = await MacLoadedFile.load(path, client: context.client)
      if selected == path { file = loaded }
    }
  }

  private func relative(_ path: String) -> String {
    guard let directory = context.directory, path.hasPrefix(directory + "/") else { return path }
    return String(path.dropFirst(directory.count + 1))
  }

  private func row(
    _ entry: DirectoryEntry, title: String, statuses: [String: ContextColumn.FileStatus], folders: Set<String>
  ) -> MacFileRow {
    // The server lists names only; dates and sizes come from this Mac when the checkout is local.
    let attributes = try? FileManager.default.attributesOfItem(atPath: entry.absolute)
    return MacFileRow(
      id: entry.absolute, name: entry.name, title: title, directory: entry.kind == .directory,
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
